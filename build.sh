#!/bin/sh
# Builds the installable web app (docs/, served by GitHub Pages) from src/app.html.
set -e
cd "$(dirname "$0")"
{
cat <<'H'
<!doctype html>
<html lang="de-CH">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black">
<meta name="apple-mobile-web-app-title" content="Bullion Monkey">
<meta name="theme-color" content="#060606">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" href="icon-180.png">
<link rel="icon" href="icon-192.png">
<style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>
H
sed -n '1,/<\/style>/p' src/app.html
echo '</head><body>'
sed '1,/<\/style>/d' src/app.html
echo '</body></html>'
} > docs/index.html
