# CineWall Website

This is a simple static landing page for `CineWall`.

## Files

- `index.html`: main landing page
- `styles.css`: all styling
- `script.js`: reveal and motion effects
- `api/activate-license.js`: server endpoint for Pro key activation
- `appcast.xml`: Sparkle update feed for the macOS app
- `updates/`: signed Sparkle archives and delta files

## What To Replace Before Launch

In [index.html](/Users/saivinaykumarreddyvavilla/Documents/SimpleVideoWallpaper/website/index.html):

- Replace `https://your-download-link.example.com` with your real download URL
- Replace the Pro checkout link with your real hosted checkout URL if it changes
- Update the final price if you change it

## Easy Deployment

1. Create a Vercel account.
2. Import this repo.
3. Keep the root directory as `./`.
4. Deploy.

You can also host this as plain static files anywhere else.

## Activation Endpoint

The website repo now includes a Vercel serverless function at:

- `/api/activate-license`

Optional Vercel environment variables:

- `LEMON_PRODUCT_NAME`
- `LEMON_PRODUCT_ID`

If you do not set either one, the endpoint defaults to checking for:

- `CineWall Pro Lifetime`

## Sparkle Hosting

The app is configured to look for updates at:

- `https://cinewall-site.vercel.app/appcast.xml`

When you prepare a new release, commit and push:

- `appcast.xml`
- everything generated inside `updates/`
