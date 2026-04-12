Add-Type -AssemblyName System.Security

$cookiesPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Network\Cookies"
$localStatePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
$tempDb = "$env:TEMP\x-cookies-extract.db"

# Copy cookies DB (Chrome locks it while running)
try {
    # Use Volume Shadow Copy via raw file read to bypass lock
    $bytes = [System.IO.File]::ReadAllBytes($cookiesPath)
    [System.IO.File]::WriteAllBytes($tempDb, $bytes)
} catch {
    Write-Error "Cannot read Chrome cookies. Close Chrome or try again."
    exit 1
}

# Get master decryption key
$localState = Get-Content $localStatePath -Raw | ConvertFrom-Json
$encKeyAll = [Convert]::FromBase64String($localState.os_crypt.encrypted_key)
$encKey = New-Object byte[] ($encKeyAll.Length - 5)
[Array]::Copy($encKeyAll, 5, $encKey, 0, $encKey.Length)
$masterKey = [System.Security.Cryptography.ProtectedData]::Unprotect($encKey, $null, "CurrentUser")

# Query cookies via ADO.NET (no sqlite3.exe dependency)
Add-Type -Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Network\..\..\..\..\..\sqlite-netFx-full-bundle-x64-2015-1.0.118.0\System.Data.SQLite.dll" -ErrorAction SilentlyContinue
# Fallback: use the copy as a raw file and parse with .NET
# Actually, simplest reliable path: use Python's sqlite3
$pythonPaths = @("python", "python3", "py")
$pyExe = $null
foreach ($p in $pythonPaths) {
    try { & $p --version 2>$null; $pyExe = $p; break } catch {}
}

if ($pyExe) {
    $pyScript = @"
import sqlite3, sys
conn = sqlite3.connect(r'$tempDb')
for name, val in conn.execute("SELECT name, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%.x.com' AND name IN ('auth_token','ct0')"):
    print(f"{name}|{val}")
conn.close()
"@
    $rows = & $pyExe -c $pyScript 2>$null
} else {
    Write-Error "No Python found. Install Python on Windows."
    Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
    exit 1
}

$result = @{}
foreach ($row in $rows) {
    $parts = $row -split "\|"
    $name = $parts[0]
    $hexVal = $parts[1]
    $rawBytes = New-Object byte[] ($hexVal.Length / 2)
    for ($i = 0; $i -lt $rawBytes.Length; $i++) {
        $rawBytes[$i] = [Convert]::ToByte($hexVal.Substring($i * 2, 2), 16)
    }
    if ($rawBytes.Length -le 15) { continue }

    $nonce = New-Object byte[] 12
    [Array]::Copy($rawBytes, 3, $nonce, 0, 12)
    $tagStart = $rawBytes.Length - 16
    $ciphertextLen = $tagStart - 15
    $ciphertext = New-Object byte[] $ciphertextLen
    [Array]::Copy($rawBytes, 15, $ciphertext, 0, $ciphertextLen)
    $tag = New-Object byte[] 16
    [Array]::Copy($rawBytes, $tagStart, $tag, 0, 16)
    $plain = New-Object byte[] $ciphertextLen
    $aes = [System.Security.Cryptography.AesGcm]::new($masterKey)
    $aes.Decrypt($nonce, $ciphertext, $tag, $plain)
    $result[$name] = [System.Text.Encoding]::UTF8.GetString($plain)
}

Remove-Item $tempDb -Force -ErrorAction SilentlyContinue

if ($result.ContainsKey('auth_token') -and $result.ContainsKey('ct0')) {
    Write-Output "$($result['auth_token'])|$($result['ct0'])"
} else {
    Write-Error "Cookies not found. Make sure you are logged into x.com in Chrome."
    exit 1
}
