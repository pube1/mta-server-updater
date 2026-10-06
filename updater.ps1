param(
    [switch]$NonInteractive
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "MTA:SA 64-Bit Sunucu Güncelleyici"

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

Clear-Host
Write-Host "==========================================================" -ForegroundColor Magenta
Write-Host "         MTA:SA 64-BIT SUNUCU GÜNCELLEME ARACI            " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Magenta

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

if (-not $7zExe) {
    Write-Err "7z.exe bulunamadı! 'tools' klasöründe veya sistemde 7-Zip kurulu olmalıdır."
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
}

$runningServers = Get-Process | Where-Object { $_.ProcessName -like "*MTA Server*" }
if ($runningServers) {
    Write-Warn "UYARI: MTA Sunucusu şu anda çalışıyor!"
    Write-Warn "Dosyaların kilitlenmemesi için lütfen sunucuyu durdurun."
    if (-not $NonInteractive) {
        $answer = Read-Host "Yine de devam edilsin mi? (E/H)"
        if ($answer -ne "E" -and $answer -ne "e") {
            Write-Host "İşlem iptal edildi."
            exit 0
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
    Write-Step "Windows Gezgini klasör seçim penceresi açılıyor..."
    
    try {
        $targetDir = [FolderPicker]::ShowDialog("MTA:SA Sunucunuzun Kurulu Olduğu Klasörü Seçin")
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "MTA:SA Sunucunuzun Kurulu Olduğu Klasörü Seçin"
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $targetDir = $dialog.SelectedPath
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($targetDir)) {
        Write-Err "Klasör seçilmedi. İşlem iptal edildi."
        if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
        exit 0
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
            exit 0
        }
    }
}

@{ ServerPath = $targetDir } | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8

Write-Step "Nightly sunucusundan en güncel 64-bit sürüm taranıyor..."
$nightlyUrl = "https://nightly.multitheftauto.com/"
$browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
try {
    $html = (Invoke-WebRequest -Uri $nightlyUrl -UserAgent $browserUA -UseBasicParsing -TimeoutSec 15).Content
} catch {
    Write-Err "Nightly sayfasına ulaşılamadı: $_"
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
}

$matchedFile = $null
if ($html -match 'href="(?<file>mtasa_x64-1\.6-rc-[^"]+\.exe)"') {
    $matchedFile = $Matches.file
} elseif ($html -match 'href="(?<file>mtasa_x64-[^"]+\.exe)"') {
    $matchedFile = $Matches.file
}

if (-not $matchedFile) {
    Write-Err "Güncel 64-bit sunucu indirme linki sayfada bulunamadı!"
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
}

$downloadUrl = "https://nightly.multitheftauto.com/$matchedFile"
Write-Success "En güncel sürüm bulundu: $matchedFile"
Write-Host "İndirme Adresi: $downloadUrl" -ForegroundColor DarkGray

$tempBase = Join-Path $env:LOCALAPPDATA "MTA_Updater"
$downloadFile = Join-Path $tempBase $matchedFile
$extractDir = Join-Path $tempBase "extracted"

if (Test-Path $tempBase) {
    Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $tempBase | Out-Null

Write-Step "Dosya indiriliyor: $matchedFile..."
try {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", $browserUA)
    $wc.DownloadFile($downloadUrl, $downloadFile)
    Write-Success "İndirme tamamlandı!"
} catch {
    Write-Err "İndirme sırasında hata oluştu: $_"
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
}

Write-Step "Dosyalar arka planda ayıklanıyor..."
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
$extractLog = Join-Path $tempBase "7z_extract.log"
$extractProcess = Start-Process -FilePath $7zExe -ArgumentList "x `"$downloadFile`" -o`"$extractDir`" -y" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $extractLog -RedirectStandardError (Join-Path $tempBase "7z_err.log")

if ($extractProcess.ExitCode -ne 0) {
    Write-Err "Arşiv ayıklanamadı! ExitCode: $($extractProcess.ExitCode)"
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
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
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
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
        if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
        exit 1
    }
}

if (Test-Path $targetX64Dir) {
    try {
        Remove-Item -Path $targetX64Dir -Recurse -Force
        Write-Success "Eski 'x64' klasörü silindi."
    } catch {
        Write-Err "'x64' klasörü silinemedi: $_"
        if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
        exit 1
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
    if (-not $NonInteractive) { Read-Host "`nÇıkmak için Enter'a basın..." }
    exit 1
}

Write-Step "Geçici dosyalar temizleniyor..."
Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   GÜNCELLEME BAŞARIYLA TAMAMLANDI! ($matchedFile)" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "Sunucunuz en son MTA:SA 64-bit sürümüne güncellendi." -ForegroundColor White

if (-not $NonInteractive) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "MTA:SA 64-Bit Sunucu başarıyla güncellendi!`n`nSürüm: $matchedFile`nKonum: $targetDir",
        "Güncelleme Başarılı",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    Read-Host "`nKapatmak için Enter'a basın..."
}
