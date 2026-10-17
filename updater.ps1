param(
    [switch]$NonInteractive,
    [string]$Mode = "1"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "MTA:SA Güncelleyici (Sunucu & Oyun)"

function Write-Step {
    param([string]$Text)
    Write-Host "`n[+] $Text" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "[X] $Text" -ForegroundColor Red
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class FolderPicker {
    [ComImport]
    [Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    [ClassInterface(ClassInterfaceType.None)]
    public class FileOpenDialogRCW {}

    [ComImport]
    [Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint fos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int alignment);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport]
    [Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    public static string ShowDialog(string title = "Klasör Seçin") {
        var dialog = (IFileOpenDialog)new FileOpenDialogRCW();
        uint options;
        dialog.GetOptions(out options);
        dialog.SetOptions(options | 0x00000020 | 0x00000040);
        if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);

        int hr = dialog.Show(IntPtr.Zero);
        if (hr == 0) {
            IShellItem item;
            dialog.GetResult(out item);
            string path;
            item.GetDisplayName(0x80058000, out path);
            return path;
        }
        return null;
    }
}
'@

function Get-7zExe {
    $7zExe = $null
    $local7z = Join-Path $PSScriptRoot "tools/7z.exe"
    if (Test-Path $local7z) {
        $7zExe = $local7z
    } elseif (Test-Path "C:/Program Files/7-Zip/7z.exe") {
        $7zExe = "C:/Program Files/7-Zip/7z.exe"
    } elseif (Test-Path "C:/Program Files (x86)/7-Zip/7z.exe") {
        $7zExe = "C:/Program Files (x86)/7-Zip/7z.exe"
    } else {
        $cmd7z = Get-Command "7z.exe" -ErrorAction SilentlyContinue
        if ($cmd7z) { $7zExe = $cmd7z.Source }
    }
    return $7zExe
}

function Select-CustomFolder {
    param([string]$Title)
    $path = $null
    try {
        $path = [FolderPicker]::ShowDialog($Title)
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Title
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $path = $dialog.SelectedPath
        }
    }
    return $path
}

function Update-MtaServer {
    $7zExe = Get-7zExe
    if (-not $7zExe) {
        Write-Err "7z.exe bulunamadı! 'tools' klasöründe veya sistemde 7-Zip kurulu olmalıdır."
        if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
        return
    }

    $runningServers = Get-Process | Where-Object { $_.ProcessName -like "*MTA Server*" }
    if ($runningServers) {
        Write-Warn "UYARI: MTA Sunucusu şu anda çalışıyor!"
        Write-Warn "Dosyaların kilitlenmemesi için lütfen sunucuyu durdurun."
        if (-not $NonInteractive) {
            $answer = Read-Host "Yine de devam edilsin mi? (E/H)"
            if ($answer -ne "E" -and $answer -ne "e") {
                Write-Host "Sunucu güncellemesi iptal edildi."
                return
            }
        }
    }

    $configFile = Join-Path $PSScriptRoot "updater_config.json"
    $targetDir = $null

    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.ServerPath -and (Test-Path $cfg.ServerPath)) {
                $savedPath = $cfg.ServerPath
                Write-Host "`nKayıtlı Sunucu Konumu: " -NoNewline
                Write-Host $savedPath -ForegroundColor Yellow
                if ($NonInteractive) {
                    $targetDir = $savedPath
                } else {
                    $choice = Read-Host "Bu konumu güncellemek için ENTER'a basın (Yeni klasör seçmek için 'S' yazın)"
                    if ([string]::IsNullOrWhiteSpace($choice)) {
                        $targetDir = $savedPath
                    }
                }
            }
        } catch {
        }
    }

    if (-not $targetDir) {
        Write-Step "Windows Gezgini sunucu klasör seçim penceresi açılıyor..."
        $targetDir = Select-CustomFolder "MTA:SA Sunucunuzun Kurulu Olduğu Klasörü Seçin"
        if ([string]::IsNullOrWhiteSpace($targetDir)) {
            Write-Err "Klasör seçilmedi. Sunucu güncellemesi iptal edildi."
            if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
            return
        }
    }

    Write-Success "Hedef Sunucu Klasörü: $targetDir"

    $hasServerExe = (Test-Path (Join-Path $targetDir "MTA Server64.exe")) -or (Test-Path (Join-Path $targetDir "MTA Server.exe"))
    $hasMods = Test-Path (Join-Path $targetDir "mods")
    if (-not $hasServerExe -and -not $hasMods) {
        Write-Warn "Dikkat: Seçtiğiniz klasörde MTA Server dosyaları veya 'mods' klasörü tespit edilemedi."
        if (-not $NonInteractive) {
            $confirm = Read-Host "Yine de bu klasöre kurulum yapılsın mı? (E/H)"
            if ($confirm -ne "E" -and $confirm -ne "e") {
                Write-Host "İşlem iptal edildi."
                return
            }
        }
    }

    $cfgObj = @{}
    if (Test-Path $configFile) {
        try { $cfgObj = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfgObj = @{} }
    }
    $cfgObj = [PSCustomObject]$cfgObj
    $cfgObj | Add-Member -NotePropertyName "ServerPath" -NotePropertyValue $targetDir -Force
    $cfgObj | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8

    Write-Step "Nightly sunucusundan en güncel 64-bit sunucu sürümü taranıyor..."
    $nightlyUrl = "https://nightly.multitheftauto.com/"
    $browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    try {
        $html = (Invoke-WebRequest -Uri $nightlyUrl -UserAgent $browserUA -UseBasicParsing -TimeoutSec 15).Content
    } catch {
        Write-Err "Nightly sayfasına ulaşılamadı: $_"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    $matchedFile = $null
    if ($html -match 'href="(?<file>mtasa_x64-1\.6-rc-[^"]+\.exe)"') {
        $matchedFile = $Matches.file
    } elseif ($html -match 'href="(?<file>mtasa_x64-[^"]+\.exe)"') {
        $matchedFile = $Matches.file
    }

    if (-not $matchedFile) {
        Write-Err "Güncel 64-bit sunucu indirme linki sayfada bulunamadı!"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    $downloadUrl = "https://nightly.multitheftauto.com/$matchedFile"
    Write-Success "En güncel sunucu sürümü bulundu: $matchedFile"
    Write-Host "İndirme Adresi: $downloadUrl" -ForegroundColor DarkGray

    $tempBase = Join-Path $env:LOCALAPPDATA "MTA_Updater"
    $downloadFile = Join-Path $tempBase $matchedFile
    $extractDir = Join-Path $tempBase "extracted"

    if (Test-Path $tempBase) {
        Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $tempBase | Out-Null

    Write-Step "Sunucu dosyası indiriliyor: $matchedFile..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", $browserUA)
        $wc.DownloadFile($downloadUrl, $downloadFile)
        Write-Success "İndirme tamamlandı!"
    } catch {
        Write-Err "İndirme sırasında hata oluştu: $_"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    Write-Step "Dosyalar arka planda ayıklanıyor..."
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    $extractLog = Join-Path $tempBase "7z_extract.log"
    $extractProcess = Start-Process -FilePath $7zExe -ArgumentList "x `"$downloadFile`" -o`"$extractDir`" -y" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $extractLog -RedirectStandardError (Join-Path $tempBase "7z_err.log")

    if ($extractProcess.ExitCode -ne 0) {
        Write-Err "Arşiv ayıklanamadı! ExitCode: $($extractProcess.ExitCode)"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }
    Write-Success "Dosyalar başarıyla ayıklandı."

    $extractedServerDir = Join-Path $extractDir "server"
    if (-not (Test-Path $extractedServerDir)) {
        $extractedServerDir = $extractDir
    }

    $newServerExe = Join-Path $extractedServerDir "MTA Server64.exe"
    $newX64Dir = Join-Path $extractedServerDir "x64"

    if (-not (Test-Path $newServerExe) -or -not (Test-Path $newX64Dir)) {
        Write-Err "Gereken dosyalar (MTA Server64.exe ve x64 klasörü) arşivde bulunamadı!"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    Write-Step "Hedef sunucu klasöründeki eski sürüm dosyaları siliniyor..."
    $targetServerExe = Join-Path $targetDir "MTA Server64.exe"
    $targetX64Dir = Join-Path $targetDir "x64"

    if (Test-Path $targetServerExe) {
        try {
            Remove-Item -Path $targetServerExe -Force
            Write-Success "Eski 'MTA Server64.exe' silindi."
        } catch {
            Write-Err "'MTA Server64.exe' silinemedi (Dosya kullanımda olabilir): $_"
            if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
            return
        }
    }

    if (Test-Path $targetX64Dir) {
        try {
            Remove-Item -Path $targetX64Dir -Recurse -Force
            Write-Success "Eski 'x64' klasörü silindi."
        } catch {
            Write-Err "'x64' klasörü silinemedi: $_"
            if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
            return
        }
    }

    Write-Step "Yeni sürüm dosyaları aktarılıyor..."
    try {
        Copy-Item -Path $newServerExe -Destination $targetDir -Force
        Write-Success "Yeni 'MTA Server64.exe' aktarıldı."
        
        Copy-Item -Path $newX64Dir -Destination $targetDir -Recurse -Force
        Write-Success "Yeni 'x64' klasörü aktarıldı."
    } catch {
        Write-Err "Kopyalama sırasında hata oluştu: $_"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    Write-Step "Geçici dosyalar temizleniyor..."
    Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "   SUNUCU GÜNCELLEMESİ TAMAMLANDI! ($matchedFile)" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
}

function Update-MtaClient {
    $runningClients = Get-Process | Where-Object { $_.ProcessName -in @("Multi Theft Auto", "proxy_sa", "gta_sa") }
    if ($runningClients) {
        Write-Warn "UYARI: MTA:SA veya GTA:SA oyunu şu anda açık!"
        Write-Warn "Dosyaların kilitlenmemesi için lütfen oyunu kapatın."
        if (-not $NonInteractive) {
            $answer = Read-Host "Yine de devam edilsin mi? (E/H)"
            if ($answer -ne "E" -and $answer -ne "e") {
                Write-Host "Oyun güncellemesi iptal edildi."
                return
            }
        }
    }

    $defaultClientDir = "C:\Program Files (x86)\MTA San Andreas 1.6"
    $regLocation = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Multi Theft Auto: San Andreas All\1.6" -ErrorAction SilentlyContinue).'Last Install Location'
    if ($regLocation -and (Test-Path $regLocation)) {
        $defaultClientDir = $regLocation
    }

    $configFile = Join-Path $PSScriptRoot "updater_config.json"
    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.ClientPath -and (Test-Path $cfg.ClientPath)) {
                $defaultClientDir = $cfg.ClientPath
            }
        } catch {
        }
    }

    $clientDir = $defaultClientDir
    Write-Host "`nVarsayılan Oyun Kurulum Konumu: " -NoNewline
    Write-Host $clientDir -ForegroundColor Yellow

    if (-not $NonInteractive) {
        $choice = Read-Host "Bu konuma kurulsun mu? (ENTER = Evet, 'S' = Farklı Klasör Seç)"
        if ($choice -eq "S" -or $choice -eq "s") {
            $selected = Select-CustomFolder "MTA:SA Oyun Klasörünü Seçin"
            if (-not [string]::IsNullOrWhiteSpace($selected)) {
                $clientDir = $selected
            }
        }
    }

    Write-Success "Hedef Oyun Klasörü: $clientDir"

    $cfgObj = @{}
    if (Test-Path $configFile) {
        try { $cfgObj = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfgObj = @{} }
    }
    $cfgObj = [PSCustomObject]$cfgObj
    $cfgObj | Add-Member -NotePropertyName "ClientPath" -NotePropertyValue $clientDir -Force
    $cfgObj | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8

    Write-Step "Nightly sunucusundan en güncel oyun (Client) sürümü taranıyor..."
    $nightlyUrl = "https://nightly.multitheftauto.com/"
    $browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    try {
        $html = (Invoke-WebRequest -Uri $nightlyUrl -UserAgent $browserUA -UseBasicParsing -TimeoutSec 15).Content
    } catch {
        Write-Err "Nightly sayfasına ulaşılamadı: $_"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    $matchedClient = $null
    if ($html -match 'href="(?<file>mtasa-1\.6-rc-[0-9]+-[0-9]+\.exe)"') {
        $matchedClient = $Matches.file
    }

    if (-not $matchedClient) {
        Write-Err "Güncel MTA:SA oyun kurulum linki bulunamadı!"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    $downloadUrl = "https://nightly.multitheftauto.com/$matchedClient"
    Write-Success "En güncel oyun sürümü bulundu: $matchedClient"
    Write-Host "İndirme Adresi: $downloadUrl" -ForegroundColor DarkGray

    $tempBase = Join-Path $env:LOCALAPPDATA "MTA_Updater"
    $downloadFile = Join-Path $tempBase $matchedClient

    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Force -Path $tempBase | Out-Null
    }

    Write-Step "Oyun kurulum dosyası indiriliyor (~130 MB, lütfen bekleyin)..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", $browserUA)
        $wc.DownloadFile($downloadUrl, $downloadFile)
        Write-Success "İndirme tamamlandı!"
    } catch {
        Write-Err "İndirme sırasında hata oluştu: $_"
        if (-not $NonInteractive) { Read-Host "`nDevam etmek için Enter'a basın..." }
        return
    }

    Write-Step "MTA:SA Oyunu güncelleniyor (Yönetici izni penceresi gelirse 'Evet'e basın)..."
    $installArgs = "/S /D=$clientDir"
    try {
        $p = Start-Process -FilePath $downloadFile -ArgumentList $installArgs -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            Write-Success "MTA:SA Oyunu başarıyla güncellendi!"
        } else {
            Write-Warn "Sessiz kurulum tamamlanamadı (ExitCode: $($p.ExitCode)). Kurulum arayüzü başlatılıyor..."
            Start-Process -FilePath $downloadFile -Verb RunAs -Wait
        }
    } catch {
        Write-Warn "Kurulum sırasında hata oluştu, standart kurulum başlatılıyor: $_"
        Start-Process -FilePath $downloadFile -Verb RunAs -Wait
    }

    Remove-Item -Path $downloadFile -Force -ErrorAction SilentlyContinue

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "   OYUN (CLIENT) GÜNCELLEMESİ TAMAMLANDI! ($matchedClient)" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
}

Clear-Host
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host "         MTA:SA OTOMATİK GÜNCELLEME ARACI                 " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Magenta

$userChoice = $Mode
if (-not $NonInteractive) {
    Write-Host "`nNe güncellemek istiyorsunuz?" -ForegroundColor Yellow
    Write-Host " [1] MTA:SA 64-Bit Sunucu (Server)"
    Write-Host " [2] MTA:SA Oyunu (Client)"
    Write-Host " [3] İkisi de (Sunucu + Oyun)"
    $inputChoice = Read-Host "`nSeçiminiz (1/2/3) [Varsayılan: 1]"
    if (-not [string]::IsNullOrWhiteSpace($inputChoice)) {
        $userChoice = $inputChoice
    }
}

if ($userChoice -eq "1") {
    Update-MtaServer
} elseif ($userChoice -eq "2") {
    Update-MtaClient
} elseif ($userChoice -eq "3") {
    Update-MtaServer
    Update-MtaClient
} else {
    Write-Err "Geçersiz seçim yapıldı."
}

if (-not $NonInteractive) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "MTA:SA Güncelleme işlemi tamamlandı!",
        "Güncelleme Başarılı",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    Read-Host "`nKapatmak için Enter'a basın..."
}
