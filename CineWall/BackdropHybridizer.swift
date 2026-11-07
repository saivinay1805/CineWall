import Foundation

struct BackdropHybridizer {
    struct Atom {
        let type: String
        let start: Int
        let size: Int
        let headerSize: Int
        var children: [Atom]

        var end: Int { start + size }
        var dataStart: Int { start + headerSize }
    }

    enum HybridizerError: LocalizedError {
        case invalidAtom(String)
        case missingAtom(String)
        case invalidMovie(String)

        var errorDescription: String? {
            switch self {
            case .invalidAtom(let message), .invalidMovie(let message):
                return message
            case .missingAtom(let atomType):
                return "Missing required MOV atom: \(atomType)"
            }
        }
    }

    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "dinf", "edts", "udta", "meta", "ilst", "tapt"
    ]
    private static let preservedVideoSTBLAtoms: Set<String> = ["sgpd", "sbgp", "csgm", "cslg"]
    private static let videoTableAtoms: Set<String> = ["stsd", "stts", "ctts", "stss", "sdtp", "stsc", "stsz", "stco", "co64"]

    static func buildHybridMovie(templateURL: URL, candidateURL: URL, destinationURL: URL) throws {
        let templateData = try Data(contentsOf: templateURL, options: [.mappedIfSafe])
        let candidateData = try Data(contentsOf: candidateURL, options: [.mappedIfSafe])

        let templateAtoms = try readAtomTree(in: templateData, start: 0, end: templateData.count)
        let candidateAtoms = try readAtomTree(in: candidateData, start: 0, end: candidateData.count)

        let templateMoov = try requireAtom("moov", in: templateAtoms)
        let candidateMoov = try requireAtom("moov", in: candidateAtoms)
        let candidateMdat = try requireAtom("mdat", in: candidateAtoms)

        let (templateVideo, templateAudio) = try locateTracks(in: templateData, moov: templateMoov)
        let (candidateVideo, candidateAudio) = try locateTracks(in: candidateData, moov: candidateMoov)

        let templateMVHD = try requireChild("mvhd", in: templateMoov)
        let candidateMVHD = try requireChild("mvhd", in: candidateMoov)
        let templateMovie = try parseMVHD(atomBytes(templateData, atom: templateMVHD))
        let candidateMovie = try parseMVHD(atomBytes(candidateData, atom: candidateMVHD))

        let templateVideoMDIA = try requireChild("mdia", in: templateVideo)
        let templateVideoMDHDAtom = try requireChild("mdhd", in: templateVideoMDIA)
        let templateVideoMDHD = try parseMDHD(data: templateData, atom: templateVideoMDHDAtom)
        let candidateVideoMDIA = try requireChild("mdia", in: candidateVideo)
        let candidateVideoMDHDAtom = try requireChild("mdhd", in: candidateVideoMDIA)
        let candidateVideoMDHD = try parseMDHD(data: candidateData, atom: candidateVideoMDHDAtom)

        let newMovieTimescale = templateMovie.timescale
        let newMovieDuration = scaleDuration(candidateMovie.duration, oldTimescale: candidateMovie.timescale, newTimescale: newMovieTimescale)
        let newVideoTimescale = templateVideoMDHD.timescale
        let newVideoDuration = scaleDuration(candidateVideoMDHD.duration, oldTimescale: candidateVideoMDHD.timescale, newTimescale: newVideoTimescale)

        let newMVHD = try patchMVHD(atomBytes(templateData, atom: templateMVHD), newTimescale: newMovieTimescale, newDuration: newMovieDuration)
        let newVideoTrack = try buildVideoTrack(
            templateData: templateData,
            templateTrack: templateVideo,
            candidateData: candidateData,
            candidateTrack: candidateVideo,
            newMovieDuration: newMovieDuration,
            newVideoTimescale: newVideoTimescale,
            newVideoDuration: newVideoDuration
        )

        var newTracks = [newVideoTrack]
        if let candidateAudio {
            newTracks.append(try buildAudioTrack(
                templateData: templateData,
                templateTrack: templateAudio,
                candidateData: candidateData,
                candidateTrack: candidateAudio,
                newMovieDuration: newMovieDuration
            ))
        } else if let templateAudio {
            newTracks.append(try buildAudioTrack(
                templateData: templateData,
                templateTrack: templateAudio,
                candidateData: candidateData,
                candidateTrack: nil,
                newMovieDuration: newMovieDuration
            ))
        }

        var otherMoovChildren = Data()
        for child in templateMoov.children where child.type != "mvhd" && child.type != "trak" {
            otherMoovChildren.append(atomBytes(templateData, atom: child))
        }
        let newMoov = makeAtom(type: "moov", payload: newMVHD + newTracks.reduce(into: Data()) { $0.append($1) } + otherMoovChildren)

        let ftyp = try requireAtom("ftyp", in: templateAtoms)
        let wide = findAtom("wide", in: templateAtoms) ?? findAtom("wide", in: candidateAtoms)

        var output = Data()
        output.append(atomBytes(templateData, atom: ftyp))
        if let wide {
            let wideSource = findAtom("wide", in: templateAtoms) != nil ? templateData : candidateData
            output.append(atomBytes(wideSource, atom: wide))
        }
        output.append(atomBytes(candidateData, atom: candidateMdat))
        output.append(newMoov)

        try output.write(to: destinationURL, options: .atomic)
    }

    private static func readAtomTree(in data: Data, start: Int, end: Int) throws -> [Atom] {
        var atoms: [Atom] = []
        var offset = start

        while offset + 8 <= end {
            let size32 = try readUInt32(data, at: offset)
            let type = try readASCII(data, at: offset + 4, length: 4)
            var size = Int(size32)
            var headerSize = 8

            if size32 == 0 {
                size = end - offset
            } else if size32 == 1 {
                size = Int(try readUInt64(data, at: offset + 8))
                headerSize = 16
            }

            guard size >= headerSize, offset + size <= end else {
                throw HybridizerError.invalidAtom("Invalid \(type) atom size while parsing MOV")
            }

            var children: [Atom] = []
            if containerTypes.contains(type) {
                var childStart = offset + headerSize
                if type == "meta" { childStart += 4 }
                children = try readAtomTree(in: data, start: childStart, end: offset + size)
            }

            atoms.append(Atom(type: type, start: offset, size: size, headerSize: headerSize, children: children))
            offset += size
        }

        return atoms
    }

    private static func findAtom(_ type: String, in atoms: [Atom]) -> Atom? {
        atoms.first { $0.type == type }
    }

    private static func requireAtom(_ type: String, in atoms: [Atom]) throws -> Atom {
        guard let atom = findAtom(type, in: atoms) else { throw HybridizerError.missingAtom(type) }
        return atom
    }

    private static func findChild(_ type: String, in atom: Atom?) -> Atom? {
        atom?.children.first { $0.type == type }
    }

    private static func requireChild(_ type: String, in atom: Atom?) throws -> Atom {
        guard let child = findChild(type, in: atom) else { throw HybridizerError.missingAtom(type) }
        return child
    }

    private static func atomBytes(_ data: Data, atom: Atom) -> Data {
        data.subdata(in: atom.start..<atom.end)
    }

    private static func payload(_ atomData: Data) -> Data {
        atomData.dropFirst(8)
    }

    private static func makeAtom(type: String, payload: Data) -> Data {
        var data = Data()
        appendUInt32(UInt32(payload.count + 8), to: &data)
        data.append(type.data(using: .ascii) ?? Data())
        data.append(payload)
        return data
    }

    private static func locateTracks(in data: Data, moov: Atom) throws -> (video: Atom, audio: Atom?) {
        var video: Atom?
        var audio: Atom?

        for child in moov.children where child.type == "trak" {
            let trackType = try classifyTrack(in: data, track: child)
            if trackType == "vide", video == nil {
                video = child
            } else if trackType == "soun", audio == nil {
                audio = child
            }
        }

        guard let video else {
            throw HybridizerError.invalidMovie("No video track found in MOV")
        }
        return (video, audio)
    }

    private static func classifyTrack(in data: Data, track: Atom) throws -> String {
        let mdia = try requireChild("mdia", in: track)
        let hdlr = try requireChild("hdlr", in: mdia)
        return try readASCII(data, at: hdlr.dataStart + 8, length: 4)
    }

    private struct MovieHeader {
        let timescale: Int
        let duration: Int
    }

    private static func parseMVHD(_ atomData: Data) throws -> MovieHeader {
        let version = try readUInt8(atomData, at: 8)
        if version == 1 {
            return MovieHeader(
                timescale: Int(try readUInt32(atomData, at: 28)),
                duration: Int(try readUInt64(atomData, at: 32))
            )
        }
        return MovieHeader(
            timescale: Int(try readUInt32(atomData, at: 20)),
            duration: Int(try readUInt32(atomData, at: 24))
        )
    }

    private static func parseMDHD(data: Data, atom: Atom) throws -> MovieHeader {
        let version = try readUInt8(data, at: atom.start + 8)
        if version == 1 {
            return MovieHeader(
                timescale: Int(try readUInt32(data, at: atom.start + 28)),
                duration: Int(try readUInt64(data, at: atom.start + 32))
            )
        }
        return MovieHeader(
            timescale: Int(try readUInt32(data, at: atom.start + 20)),
            duration: Int(try readUInt32(data, at: atom.start + 24))
        )
    }

    private static func patchMVHD(_ atomData: Data, newTimescale: Int, newDuration: Int) throws -> Data {
        var data = atomData
        let version = try readUInt8(data, at: 8)
        if version == 1 {
            writeUInt32(UInt32(newTimescale), to: &data, at: 28)
            writeUInt64(UInt64(newDuration), to: &data, at: 32)
        } else {
            writeUInt32(UInt32(newTimescale), to: &data, at: 20)
            writeUInt32(UInt32(newDuration), to: &data, at: 24)
        }
        return data
    }

    private static func patchTKHD(_ atomData: Data, newDuration: Int, widthHeightTail: Data?) throws -> Data {
        var data = atomData
        let version = try readUInt8(data, at: 8)
        if version == 1 {
            writeUInt64(UInt64(newDuration), to: &data, at: 36)
        } else {
            writeUInt32(UInt32(newDuration), to: &data, at: 28)
        }
        if let widthHeightTail, widthHeightTail.count == 8 {
            data.replaceSubrange((data.count - 8)..<data.count, with: widthHeightTail)
        }
        return data
    }

    private static func patchMDHD(_ atomData: Data, newTimescale: Int, newDuration: Int) throws -> Data {
        var data = atomData
        let version = try readUInt8(data, at: 8)
        if version == 1 {
            writeUInt32(UInt32(newTimescale), to: &data, at: 28)
            writeUInt64(UInt64(newDuration), to: &data, at: 32)
        } else {
            writeUInt32(UInt32(newTimescale), to: &data, at: 20)
            writeUInt32(UInt32(newDuration), to: &data, at: 24)
        }
        return data
    }

    private static func patchELST(_ atomData: Data, newSegmentDuration: Int) throws -> Data {
        var data = atomData
        let version = try readUInt8(data, at: 8)
        let entryCount = try readUInt32(data, at: 12)
        guard entryCount > 0 else { return data }
        if version == 1 {
            writeUInt64(UInt64(newSegmentDuration), to: &data, at: 16)
        } else {
            writeUInt32(UInt32(newSegmentDuration), to: &data, at: 16)
        }
        return data
    }

    private static func patchEDTS(_ atomData: Data, newSegmentDuration: Int) throws -> Data {
        guard String(data: atomData[4..<8], encoding: .ascii) == "edts" else { return atomData }
        var offset = 8
        var payload = Data()
        while offset + 8 <= atomData.count {
            let childSize = Int(try readUInt32(atomData, at: offset))
            guard childSize >= 8, offset + childSize <= atomData.count else { break }
            let child = atomData.subdata(in: offset..<(offset + childSize))
            let childType = try readASCII(atomData, at: offset + 4, length: 4)
            if childType == "elst" {
                payload.append(try patchELST(child, newSegmentDuration: newSegmentDuration))
            } else {
                payload.append(child)
            }
            offset += childSize
        }
        return makeAtom(type: "edts", payload: payload)
    }

    private static func buildSTBL(templateData: Data, templateSTBL: Atom, candidateData: Data, candidateSTBL: Atom) throws -> Data {
        let candidateChildrenByType = Dictionary(uniqueKeysWithValues: candidateSTBL.children.filter { videoTableAtoms.contains($0.type) }.map { ($0.type, $0) })
        guard candidateChildrenByType["stsd"] != nil else {
            throw HybridizerError.invalidMovie("Candidate video track has no stsd atom")
        }

        var orderedChildren: [Data] = []
        var usedTypes = Set<String>()

        for child in templateSTBL.children {
            if preservedVideoSTBLAtoms.contains(child.type) {
                orderedChildren.append(atomBytes(templateData, atom: child))
            } else if videoTableAtoms.contains(child.type), let candidateChild = candidateChildrenByType[child.type] {
                orderedChildren.append(atomBytes(candidateData, atom: candidateChild))
                usedTypes.insert(child.type)
            }
        }

        for child in candidateSTBL.children where videoTableAtoms.contains(child.type) && !usedTypes.contains(child.type) {
            orderedChildren.append(atomBytes(candidateData, atom: child))
        }

        return makeAtom(type: "stbl", payload: orderedChildren.reduce(into: Data()) { $0.append($1) })
    }

    private static func buildMINF(templateData: Data, templateMINF: Atom, candidateData: Data, candidateMINF: Atom) throws -> Data {
        let vmhd = findChild("vmhd", in: templateMINF) ?? findChild("vmhd", in: candidateMINF)
        let hdlr = findChild("hdlr", in: templateMINF) ?? findChild("hdlr", in: candidateMINF)
        let dinf = findChild("dinf", in: templateMINF) ?? findChild("dinf", in: candidateMINF)
        let templateSTBL = try requireChild("stbl", in: templateMINF)
        let candidateSTBL = try requireChild("stbl", in: candidateMINF)
        let stbl = try buildSTBL(
            templateData: templateData,
            templateSTBL: templateSTBL,
            candidateData: candidateData,
            candidateSTBL: candidateSTBL
        )

        var payload = Data()
        for atom in [vmhd, hdlr, dinf].compactMap({ $0 }) {
            let sourceData = templateMINF.children.contains(where: { $0.start == atom.start && $0.type == atom.type }) ? templateData : candidateData
            payload.append(atomBytes(sourceData, atom: atom))
        }
        payload.append(stbl)
        return makeAtom(type: "minf", payload: payload)
    }

    private static func buildMDIA(templateData: Data, templateMDIA: Atom, candidateData: Data, candidateMDIA: Atom, newVideoTimescale: Int, newVideoDuration: Int) throws -> Data {
        let candidateMDHDAtom = try requireChild("mdhd", in: candidateMDIA)
        let mdhd = try patchMDHD(atomBytes(candidateData, atom: candidateMDHDAtom), newTimescale: newVideoTimescale, newDuration: newVideoDuration)
        let templateHDLRAtom = try requireChild("hdlr", in: templateMDIA)
        let hdlr = atomBytes(templateData, atom: templateHDLRAtom)
        let templateMINF = try requireChild("minf", in: templateMDIA)
        let candidateMINF = try requireChild("minf", in: candidateMDIA)
        let minf = try buildMINF(
            templateData: templateData,
            templateMINF: templateMINF,
            candidateData: candidateData,
            candidateMINF: candidateMINF
        )
        return makeAtom(type: "mdia", payload: mdhd + hdlr + minf)
    }

    private static func buildVideoTrack(templateData: Data, templateTrack: Atom, candidateData: Data, candidateTrack: Atom, newMovieDuration: Int, newVideoTimescale: Int, newVideoDuration: Int) throws -> Data {
        let templateTKHDAtom = try requireChild("tkhd", in: templateTrack)
        let candidateTKHDAtom = try requireChild("tkhd", in: candidateTrack)
        let templateTKHD = atomBytes(templateData, atom: templateTKHDAtom)
        let candidateTKHD = atomBytes(candidateData, atom: candidateTKHDAtom)
        let tkhd = try patchTKHD(templateTKHD, newDuration: newMovieDuration, widthHeightTail: Data(candidateTKHD.suffix(8)))
        let tapt = findChild("tapt", in: templateTrack) ?? findChild("tapt", in: candidateTrack)
        let edtsAtom = findChild("edts", in: templateTrack) ?? findChild("edts", in: candidateTrack)
        let edtsSourceData = findChild("edts", in: templateTrack) != nil ? templateData : candidateData
        let edts = try edtsAtom.map { try patchEDTS(atomBytes(edtsSourceData, atom: $0), newSegmentDuration: newMovieDuration) } ?? Data()
        let templateMDIA = try requireChild("mdia", in: templateTrack)
        let candidateMDIA = try requireChild("mdia", in: candidateTrack)
        let mdia = try buildMDIA(
            templateData: templateData,
            templateMDIA: templateMDIA,
            candidateData: candidateData,
            candidateMDIA: candidateMDIA,
            newVideoTimescale: newVideoTimescale,
            newVideoDuration: newVideoDuration
        )

        var payload = Data()
        payload.append(tkhd)
        if let tapt {
            let sourceData = templateTrack.children.contains(where: { $0.start == tapt.start && $0.type == tapt.type }) ? templateData : candidateData
            payload.append(atomBytes(sourceData, atom: tapt))
        }
        payload.append(edts)
        payload.append(mdia)
        return makeAtom(type: "trak", payload: payload)
    }

    private static func buildAudioTrack(templateData: Data, templateTrack: Atom?, candidateData: Data, candidateTrack: Atom?, newMovieDuration: Int) throws -> Data {
        guard let sourceTrack = templateTrack ?? candidateTrack else {
            throw HybridizerError.invalidMovie("No audio track available")
        }
        let sourceData = templateTrack != nil ? templateData : candidateData
        let sourceTKHDAtom = try requireChild("tkhd", in: sourceTrack)
        let sourceTKHD = atomBytes(sourceData, atom: sourceTKHDAtom)
        let candidateTKHD: Data
        if let candidateTrack {
            let candidateTKHDAtom = try requireChild("tkhd", in: candidateTrack)
            candidateTKHD = atomBytes(candidateData, atom: candidateTKHDAtom)
        } else {
            candidateTKHD = sourceTKHD
        }
        let tkhd = try patchTKHD(sourceTKHD, newDuration: newMovieDuration, widthHeightTail: Data(candidateTKHD.suffix(8)))

        let sourceEDTS = findChild("edts", in: sourceTrack)
        let candidateEDTS = candidateTrack.flatMap { findChild("edts", in: $0) }
        let edtsAtom = sourceEDTS ?? candidateEDTS
        let edtsDataSource = sourceEDTS != nil || candidateTrack == nil ? sourceData : candidateData
        let edts = try edtsAtom.map { try patchEDTS(atomBytes(edtsDataSource, atom: $0), newSegmentDuration: newMovieDuration) } ?? Data()

        let candidateMDIA = try requireChild("mdia", in: candidateTrack ?? sourceTrack)
        let candidateMDHDAtom = try requireChild("mdhd", in: candidateMDIA)
        let candidateMDHDSource = candidateTrack != nil ? candidateData : sourceData
        let candidateMDHD = atomBytes(candidateMDHDSource, atom: candidateMDHDAtom)
        let candidateAudioMDHD = try parseMDHD(data: candidateMDHDSource, atom: candidateMDHDAtom)
        let mdhd = try patchMDHD(candidateMDHD, newTimescale: candidateAudioMDHD.timescale, newDuration: candidateAudioMDHD.duration)

        let sourceMDIA = try requireChild("mdia", in: sourceTrack)
        let sourceHDLRAtom = try requireChild("hdlr", in: sourceMDIA)
        let hdlr = atomBytes(sourceData, atom: sourceHDLRAtom)
        let candidateMINF = try requireChild("minf", in: candidateMDIA)
        let sourceMINF = try requireChild("minf", in: sourceMDIA)
        let sourceSMHDAtom = try requireChild("smhd", in: sourceMINF)
        let sourceMINFHDLRAtom = try requireChild("hdlr", in: sourceMINF)
        let sourceDINFAtom = try requireChild("dinf", in: sourceMINF)
        let candidateSTBLAtom = try requireChild("stbl", in: candidateMINF)
        let smhd = atomBytes(sourceData, atom: sourceSMHDAtom)
        let minfHDLR = atomBytes(sourceData, atom: sourceMINFHDLRAtom)
        let dinf = atomBytes(sourceData, atom: sourceDINFAtom)
        let stbl = atomBytes(candidateMDHDSource, atom: candidateSTBLAtom)
        let minf = makeAtom(type: "minf", payload: smhd + minfHDLR + dinf + stbl)
        let mdia = makeAtom(type: "mdia", payload: mdhd + hdlr + minf)
        return makeAtom(type: "trak", payload: tkhd + edts + mdia)
    }

    private static func scaleDuration(_ duration: Int, oldTimescale: Int, newTimescale: Int) -> Int {
        guard oldTimescale != 0 else { return duration }
        return Int((Double(duration) * Double(newTimescale) / Double(oldTimescale)).rounded())
    }

    private static func readUInt8(_ data: Data, at offset: Int) throws -> UInt8 {
        guard offset < data.count else { throw HybridizerError.invalidAtom("Unexpected end of MOV data") }
        return data[offset]
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw HybridizerError.invalidAtom("Unexpected end of MOV data") }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset + 8 <= data.count else { throw HybridizerError.invalidAtom("Unexpected end of MOV data") }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private static func readASCII(_ data: Data, at offset: Int, length: Int) throws -> String {
        guard offset + length <= data.count else { throw HybridizerError.invalidAtom("Unexpected end of MOV data") }
        return String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii) ?? ""
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private static func writeUInt64(_ value: UInt64, to data: inout Data, at offset: Int) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
