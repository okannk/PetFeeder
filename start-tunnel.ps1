# PetFeeder - Cloudflare Tunnel Başlatıcı
# Kullanım: PowerShell'de .\start-tunnel.ps1
#
# Gereksinim: cloudflared kurulu olmalı
# İndir: https://github.com/cloudflare/cloudflared/releases
# (cloudflared-windows-amd64.exe → cloudflared.exe olarak PATH'e ekle)

$PORT = 3001
$BACKEND_DIR = "$PSScriptRoot\backend"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   PetFeeder - Uzak Erişim Başlatılıyor" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# cloudflared mevcut mu kontrol et
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    Write-Host "HATA: cloudflared bulunamadı!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Kurulum için:" -ForegroundColor Yellow
    Write-Host "  1. https://github.com/cloudflare/cloudflared/releases adresine git"
    Write-Host "  2. cloudflared-windows-amd64.exe indir"
    Write-Host "  3. cloudflared.exe olarak yeniden adlandır"
    Write-Host "  4. C:\Windows\System32\ klasörüne taşı (veya PATH'e ekle)"
    Write-Host ""
    Read-Host "Çıkmak için Enter'a bas"
    exit 1
}

# Backend'i başlat (arka planda)
Write-Host "Backend başlatılıyor..." -ForegroundColor Yellow
$backend = Start-Process -FilePath "node" -ArgumentList "server.js" -WorkingDirectory $BACKEND_DIR -PassThru -WindowStyle Normal

Start-Sleep -Seconds 2

if ($backend.HasExited) {
    Write-Host "HATA: Backend başlatılamadı!" -ForegroundColor Red
    Read-Host "Çıkmak için Enter'a bas"
    exit 1
}

Write-Host "Backend çalışıyor (PID: $($backend.Id))" -ForegroundColor Green
Write-Host ""

# Cloudflare tünelini başlat
Write-Host "Cloudflare tüneli açılıyor..." -ForegroundColor Yellow
Write-Host "(URL birkaç saniye içinde aşağıda görünecek)" -ForegroundColor Gray
Write-Host ""
Write-Host "------- TUNNEL URL -------" -ForegroundColor Magenta

# cloudflared çalıştır — URL'yi stdout'a yazar
$tunnel = Start-Process -FilePath "cloudflared" -ArgumentList "tunnel --url http://localhost:$PORT" -PassThru -NoNewWindow

Write-Host ""
Write-Host "Yukarıdaki 'trycloudflare.com' adresini kopyalayıp" -ForegroundColor Cyan
Write-Host "uygulamada Ayarlar → Backend Adresi alanına yapıştır." -ForegroundColor Cyan
Write-Host ""
Write-Host "Kapatmak için bu pencereyi kapatın." -ForegroundColor Gray
Write-Host ""

# İkisi de kapanana kadar bekle
$tunnel.WaitForExit()
$backend.Kill()
