# CineWall Website

This is a simple static landing page for `CineWall`.

## Files

- `index.html`: main landing page
- `styles.css`: all styling
- `script.js`: reveal and motion effects
- `api/activate-license.js`: server endpoint for Pro key activation
- `api/admin-stats.js`: private dashboard stats endpoint
- `api/trial-status.js`: server endpoint for the server-backed 7-day trial
- `appcast.xml`: Sparkle update feed for the macOS app
- `updates/`: signed Sparkle archives and delta files

## What To Replace Before Launch

In [index.html](./website/index.html):

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
- `/api/trial-status`
- `/api/admin-stats`

Optional Vercel environment variables:

- `LEMON_PRODUCT_NAME`
- `LEMON_PRODUCT_ID`

If you do not set either one, the endpoint defaults to checking for:

- `CineWall Pro Lifetime`

## Server-Backed Trial

The Pro trial now uses a server-backed endpoint instead of trusting only local time on the Mac.

The macOS app sends:

- `install_id`
- `device_name`
- `action` (`status` or `start`)

The endpoint stores one 7-day trial record per install in Vercel KV / Upstash Redis.

Required Vercel environment variables for the trial endpoint:

- `KV_REST_API_URL` or `UPSTASH_REDIS_REST_URL`
- `KV_REST_API_TOKEN` or `UPSTASH_REDIS_REST_TOKEN`

If those variables are missing, `/api/trial-status` returns a clear configuration error instead of silently falling back.

The app now also sends:

- `os_version`
- `architecture`
- `app_version`

That metadata is used for the admin dashboard breakdowns.

## Private Admin Dashboard

The website repo now includes a private dashboard at:

- `/admin.html`

Required Vercel environment variable:

- `ADMIN_TOKEN`

Open the page, enter that token, and the dashboard will load:

- GitHub release downloads
- total trial starts
- active trials
- successful license activations
- breakdowns by macOS version
- breakdowns by Intel vs Apple Silicon

## Sparkle Hosting

The app is configured to look for updates at:

- `https://cinewall-site.vercel.app/appcast.xml`

When you prepare a new release, commit and push:

- `appcast.xml`
- everything generated inside `updates/`
