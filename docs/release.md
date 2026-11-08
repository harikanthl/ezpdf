# Releasing ezPDF

ezPDF ships as a Developer ID–signed, notarized DMG, the same way as ezRecord (without Sparkle: ezPDF doesn't
update itself yet, so people download new versions from the site).

## One-time setup (already done on this Mac)

1. **Signing:** the "Developer ID Application: Harikanth Lingutla (2F5YSX6AK6)" certificate is in the login Keychain.
2. **Notarization:** the `KekasatoriNotary` notarytool profile (shared with ezRecord, Owlish and ezHide).
3. **Hosting:** R2 bucket `harikanth-downloads` behind `dl.harikanth.site`; ezPDF lives under `/ezpdf/`. The site's
   download button goes through `/api/ezpdf/download`, which redirects to the current DMG (`DMG_URL` in
   harikanth-site `functions/api/ezpdf/download.ts`).

## Each release

```
scripts/release.sh 1.0.1          # build number defaults to the commit count
```

It archives a Release build, signs the app with Developer ID (hardened runtime, the app's entitlements, a secure
timestamp), makes `build/shipped/ezPDF-<version>.dmg`, signs, notarizes and staples it, and uploads it. Then bump
`DMG_URL` on the site and deploy it. Keep shipped DMGs in `build/shipped/`.

`SKIP_NOTARIZE=1 scripts/release.sh 0.0.1` makes an un-notarized DMG for a local check; `SKIP_UPLOAD=1` stops
before publishing.
