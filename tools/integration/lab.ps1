[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Check', 'Setup', 'Start', 'Stop', 'Preflight', 'Smoke', 'Contract', 'Web', 'Flutter',
                 'Emulator', 'Android', 'DatabaseStart', 'DatabaseTest', 'DatabaseStop')]
    [string]$Action,
    [ValidateSet('Synthetic', 'Staging', 'Local')]
    [string]$Profile = 'Synthetic',
    [string]$Python,
    [string]$Avd = 'ITDA_Lab',
    [string]$AvdHome,
    [switch]$Headless,
    [switch]$InstallMock,
    [switch]$Instrumented,
    [switch]$RestartCheck,
    [switch]$WebPreview,
    [switch]$Isolated,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$backend = Join-Path $root 'services\backend'
$web = Join-Path $root 'apps\web'
$mobile = Join-Path $root 'apps\mobile'
$android = Join-Path $mobile 'android'
$runtime = Join-Path $root '.cache\itda-lab'
$venv = Join-Path $runtime 'backend-venv'
$labPython = Join-Path $venv 'Scripts\python.exe'
$stateFile = Join-Path $runtime 'services.json'
$dbWorkdir = Join-Path $runtime 'database'
$targets = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lab-targets.json') -Raw | ConvertFrom-Json
$apiUrl = 'http://127.0.0.1:8000'
$webUrl = 'http://127.0.0.1:3000'
$mockUrl = 'http://127.0.0.1:8782'
$harnessProfile = @{ Synthetic = 'fixture'; Staging = 'c1'; Local = 'local' }[$Profile]
$androidProperties = @{}
$savedEnvironment = @{}
$http = $null
$lock = $null
$exitCode = 0

function Block([string]$Message) { throw "BLOCKED $Message" }
function Fail([string]$Message) { throw "FAIL $Message" }

function Set-LabEnv([string]$Name, $Value) {
    if (-not $savedEnvironment.ContainsKey($Name)) {
        $savedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }
}

function Clear-LabEnv {
    Get-ChildItem Env: | Where-Object {
        $_.Name -match '^(ITDA_|NEXT_PUBLIC_|SUPABASE_|UVICORN_|PG(HOST|HOSTADDR|PORT|DATABASE|USER|PASSWORD|PASSFILE|SERVICE|SERVICEFILE|OPTIONS|SSL.*)$)' -or
        $_.Name -in @('DATABASE_URL', 'DATABASE_PASSWORD', 'POSTGRES_PASSWORD', 'JWT_SECRET', 'SERVICE_ROLE_KEY',
                       'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY',
                       'GEMINI_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS', 'NODE_ENV', 'NODE_OPTIONS', 'PYTHONPATH')
    } | ForEach-Object { Set-LabEnv $_.Name $null }
    Set-LabEnv NEXT_TELEMETRY_DISABLED '1'
    Set-LabEnv FLUTTER_SUPPRESS_ANALYTICS 'true'
    Set-LabEnv SUPABASE_TELEMETRY_DISABLED 'true'
}

function Find-Executable([string]$Name, [string[]]$Candidates = @()) {
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
}

function Require-Tool($Path, [string]$Instructions) {
    if (-not $Path) { Block $Instructions }
}

function Require-LabPython {
    if (-not (Test-Path -LiteralPath $labPython -PathType Leaf)) { Block 'Run Setup to install the locked backend environment.' }
    $version = Invoke-Captured $labPython @('--version')
    if ($version.code -or $version.stdout -notmatch '^Python 3\.(12|13)\.') {
        Block 'The lab Python interpreter is unavailable. Run Setup with a compatible Python path.'
    }
}

function Invoke-Captured([string]$Exe, [string[]]$Arguments) {
    # Windows PowerShell treats redirected native stderr as an error record.
    $ErrorActionPreference = 'Continue'
    $stdout = & $Exe @Arguments 2>$null
    return @{ code = $LASTEXITCODE; stdout = $stdout }
}

function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments *> $null
    return $LASTEXITCODE
}

function Invoke-LabCommand([string]$Directory, [string]$Exe, [string[]]$Arguments) {
    Push-Location -LiteralPath $Directory
    try {
        & $Exe @Arguments
        if ($LASTEXITCODE) { Fail "$([IO.Path]::GetFileName($Exe)) exited with code $LASTEXITCODE." }
    } finally { Pop-Location }
}

function Assert-WebEnvironment {
    foreach ($file in @('.env', '.env.local', '.env.development', '.env.development.local', '.env.production', '.env.production.local')) {
        if (Test-Path -LiteralPath (Join-Path $web $file)) {
            Block "Next.js auto-loads apps/web/$file. Use a lab checkout without that file and configure the selected lab profile."
        }
    }
}

function Get-PrivateSettings {
    if ($Profile -eq 'Synthetic') { return @{} }
    $prefix = "ITDA_LAB_$($Profile.ToUpperInvariant())_"
    $names = @('PUBLIC_KEY', 'JWT_ALGORITHM', 'A_EMAIL', 'A_PASSWORD', 'B_EMAIL', 'B_PASSWORD',
               'DATABASE_URL', 'SYNC_CURSOR_SECRET', 'SERVICE_ROLE_KEY')
    if ($Profile -eq 'Local') { $names += 'JWT_SECRET' }
    $allowed = $names |
        ForEach-Object { $prefix + $_ }
    $fileName = '.env.lab.' + $Profile.ToLowerInvariant()
    $path = Join-Path $root $fileName
    $values = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ($line -match '^\s*(#.*)?$') { continue }
            $entry = [regex]::Match($line, '^([A-Z0-9_]+)=(.*)$')
            $keyName = $entry.Groups[1].Value
            if (-not $entry.Success -or $keyName -cnotin $allowed -or $values.ContainsKey($keyName)) {
                Fail "Invalid setting in $fileName. Use the matching template and literal NAME=value lines."
            }
            $values[$keyName] = $entry.Groups[2].Value
        }
    }
    foreach ($name in $allowed) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
    }
    return $values
}

function Confirm-PublicKey([string]$Key) {
    if ($Key -cmatch '^sb_publishable_[A-Za-z0-9_-]+$') { return }
    if ($Profile -eq 'Local' -and $Key -cmatch '^[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+$') {
        try {
            $encoded = $Matches[1].Replace('-', '+').Replace('_', '/')
            $encoded += '=' * ((4 - $encoded.Length % 4) % 4)
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
            if ($claims.role -ceq 'anon') { return }
        } catch { }
    }
    Fail 'Supply the selected Supabase public client key. Check the matching template.'
}

function Assert-FreePort([int]$Port) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $listener.ExclusiveAddressUse = $true
    try { $listener.Start() } catch { Block "Loopback port $Port is in use or reserved." } finally { $listener.Stop() }
}

function Read-Http([string]$Url) {
    try {
        $response = $http.GetAsync($Url).GetAwaiter().GetResult()
        try {
            return @{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        } finally { $response.Dispose() }
    } catch { return $null }
}

function Open-LabLock([string]$Resource) {
    try { return [IO.File]::Open((Join-Path $runtime "$Resource.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { Block 'A lab lifecycle command is already running in this checkout.' }
}

function Get-OwnedProcess($Record) {
    $process = Get-Process -Id $Record.pid -ErrorAction SilentlyContinue
    if ($process -and $process.StartTime.ToUniversalTime().Ticks.ToString() -eq $Record.started -and
        $process.Path -eq $Record.executable) { return $process }
}

function Save-Services($Records) {
    $pending = $stateFile + '.tmp'
    @{ profile = $Profile; processes = @($Records) } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $pending -Encoding UTF8
    Move-Item -LiteralPath $pending -Destination $stateFile -Force
}

function Stop-OwnedServices($Records, $Keep = @()) {
    $remaining = @()
    foreach ($record in $Records) {
        if (Get-OwnedProcess $record) {
            $null = Invoke-Quiet "$env:SystemRoot\System32\taskkill.exe" @('/PID', $record.pid, '/T', '/F')
            if (Get-OwnedProcess $record) { $remaining += $record }
            else { Write-Host "PASS Stopped $($record.name)" }
        }
    }
    Save-Services (@($Keep) + $remaining)
    if ($remaining.Count) { Fail 'Some owned processes could not be stopped. Retry Stop in the shell that launched them.' }
}

function Use-LocalDocker {
    Set-LabEnv DOCKER_CONTEXT $null
    Set-LabEnv DOCKER_HOST 'npipe:////./pipe/dockerDesktopLinuxEngine'
}

function Get-LocalDockerEngine {
    if ($docker) {
        $result = Invoke-Captured $docker @('info', '--format', '{{.OSType}}')
        if (-not $result.code) { return $result.stdout }
    }
}

function Start-LabService($Service) {
    $exe = $Service.exe
    $arguments = $Service.arguments
    $options = @{ WorkingDirectory = $Service.directory; PassThru = $true; WindowStyle = 'Hidden' }
    if ($Profile -eq 'Synthetic') {
        $options.RedirectStandardOutput = Join-Path $runtime ($Service.name + '.out.log')
        $options.RedirectStandardError = Join-Path $runtime ($Service.name + '.err.log')
    } else {
        # Keep authenticated process output out of the terminal and files.
        $quiet = 'import subprocess,sys; sys.exit(subprocess.call(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))'
        $arguments = @('-c', $quiet, $exe) + $arguments
        $exe = $labPython
    }
    $argv = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath $exe -ArgumentList $argv @options
    return @{ name = $Service.name; pid = $process.Id; started = $process.StartTime.ToUniversalTime().Ticks.ToString();
              executable = $exe }
}

function Wait-LabService($Service, $Record) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        if (-not (Get-OwnedProcess $Record)) {
            if (-not (Get-Process -Id $Record.pid -ErrorAction SilentlyContinue)) { Fail "$($Service.name) exited during startup." }
            Start-Sleep -Seconds 1
            continue
        }
        $reply = Read-Http $Service.readiness
        if ($reply -and $reply.Status -eq $Service.status) {
            if ($Service.name -eq 'api') {
                $health = $reply.Body | ConvertFrom-Json
                if ($health.mode -ne $Service.mode -or $health.status -ne 'ok' -or
                    (($health.persistence -eq 'volatile-memory') -ne ($Profile -eq 'Synthetic'))) {
                    Fail 'API process mode or persistence does not match the selected profile.'
                }
                $storage = if ($health.persistence -in @('volatile-memory', 'unconfigured')) { $health.persistence } else { 'configured' }
                Write-Host "PASS API HTTP ready ($($health.mode), $storage)"
            } else { Write-Host "PASS $($Service.name) HTTP ready" }
            return
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    Fail "$($Service.name) did not pass its HTTP readiness check within 90 seconds."
}

function Start-LabServices($PrivateSettings, $State, $Owned) {
    Require-LabPython
    if ($Owned.Count -and $State.profile -ne $Profile) { Block 'Stop the running lab profile before switching profiles.' }
    $mode = 'fixture'
    $webMode = 'fixture'
    $webPath = '/'
    $canStartWeb = $true
    $authUrl = $null
    $publicKey = $null
    $apiSettings = @{}
    if ($Profile -ne 'Synthetic') {
        $mode = 'production'
        $webMode = 'api'
        $webPath = '/login'
        $authUrl = $targets.$harnessProfile.auth_url
        $prefix = "ITDA_LAB_$($Profile.ToUpperInvariant())_"
        $publicKey = $PrivateSettings["${prefix}PUBLIC_KEY"]
        $canStartWeb = -not [string]::IsNullOrWhiteSpace($publicKey)
        if ($canStartWeb) { Confirm-PublicKey $publicKey }
        $databaseUrl = $PrivateSettings["${prefix}DATABASE_URL"]
        if ($Profile -eq 'Local' -and $databaseUrl) {
            $dbUri = $null
            if (-not [uri]::TryCreate($databaseUrl, [UriKind]::Absolute, [ref]$dbUri) -or
                -not $dbUri.IsLoopback -or $dbUri.Scheme -notin @('postgres', 'postgresql', 'postgresql+asyncpg') -or
                [uri]::UnescapeDataString($dbUri.Query) -match '(?i)[?&]host=') {
                Block 'The Local database URL must target the disposable loopback PostgreSQL host directly.'
            }
        }
        $algorithm = $PrivateSettings["${prefix}JWT_ALGORITHM"]
        $issuer = "$authUrl/auth/v1"
        $apiSettings = @{
            ITDA_DATABASE_URL = $databaseUrl
            ITDA_SYNC_CURSOR_SECRET = $PrivateSettings["${prefix}SYNC_CURSOR_SECRET"]
            ITDA_SUPABASE_SERVICE_ROLE_KEY = $PrivateSettings["${prefix}SERVICE_ROLE_KEY"]
            ITDA_SUPABASE_JWT_ISSUER = $issuer
            ITDA_SUPABASE_JWT_ALGORITHM = $algorithm
        }
        if ($Profile -eq 'Local' -and $algorithm -eq 'HS256') {
            $apiSettings.ITDA_SUPABASE_JWT_SECRET = $PrivateSettings["${prefix}JWT_SECRET"]
        } else {
            $apiSettings.ITDA_SUPABASE_JWKS_URL = "$issuer/.well-known/jwks.json"
        }
    }
    $services = @(
        @{ name = 'api'; port = 8000; readiness = "$apiUrl/health"; status = 200; mode = $mode; exe = $labPython;
           directory = $runtime; arguments = @('-m', 'uvicorn', 'app.main:app', '--app-dir', $backend,
                                               '--host', '127.0.0.1', '--port', '8000', '--no-access-log') }
    )
    if ($Profile -eq 'Synthetic') {
        $services += @{ name = 'android-mock'; port = 8782; readiness = "$mockUrl/v1/contents"; status = 401; exe = $labPython;
            directory = $root; arguments = @((Join-Path $mobile 'tool\mock_upload_server.py'), '--seed-catalog',
                                            '--sync-page-size', '2', '--replay-sync-prefix') }
    }
    if ($canStartWeb) {
        Require-Tool $node 'Install supported Node.js and npm.'
        Assert-WebEnvironment
        $next = Join-Path $web 'node_modules\next\dist\bin\next'
        if (-not (Test-Path -LiteralPath $next)) { Block 'Run Setup to install the Web dependencies.' }
        $services += @{ name = 'web'; port = 3000; readiness = "$webUrl$webPath"; status = 200; exe = $node;
            directory = $web; arguments = @($next, 'dev', '--webpack', '--hostname', '127.0.0.1', '--port', '3000') }
    }

    foreach ($service in $services) {
        if ($service.name -notin $Owned.name) { Assert-FreePort $service.port }
    }
    $records = @($Owned)
    $started = @()
    try {
        foreach ($service in $services) {
            $record = $records | Where-Object { $_.name -eq $service.name } | Select-Object -First 1
            if (-not $record) {
                if ($service.name -eq 'api') {
                    Set-LabEnv ITDA_MODE $mode
                    Set-LabEnv ITDA_ENVIRONMENT 'local'
                    Set-LabEnv ITDA_SUPABASE_URL $authUrl
                    foreach ($entry in $apiSettings.GetEnumerator()) { Set-LabEnv $entry.Key $entry.Value }
                }
                if ($service.name -eq 'web') {
                    Set-LabEnv ITDA_MODE $null
                    Set-LabEnv ITDA_SUPABASE_URL $null
                    Set-LabEnv ITDA_DATA_MODE $webMode
                    Set-LabEnv ITDA_API_BASE_URL $apiUrl
                    Set-LabEnv NEXT_PUBLIC_SUPABASE_URL $authUrl
                    Set-LabEnv NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY $publicKey
                }
                try {
                    $record = Start-LabService $service
                } finally {
                    if ($service.name -eq 'api') {
                        foreach ($name in $apiSettings.Keys) { Set-LabEnv $name $null }
                    }
                }
                $started += $record
                $records += $record
                Save-Services $records
            }
            Wait-LabService $service $record
        }
    } catch {
        Stop-OwnedServices $started $Owned
        throw
    }
    if (-not $canStartWeb) { Block 'API-mode Web startup requires the selected Supabase public key.' }
    Write-Host "PASS $Profile services ready. API $apiUrl; Web $webUrl"
}

function Set-AndroidTools {
    Require-Tool $flutter 'Install Flutter or set flutter.sdk in apps/mobile/android/local.properties.'
    Require-Tool $adb 'Install Android platform-tools or configure ANDROID_HOME.'
    if (-not $sdk) { Block 'Configure the Android SDK through ANDROID_HOME or local.properties.' }
    if (-not (Test-Path -LiteralPath (Join-Path $jdk 'bin\java.exe'))) { Block 'Set JAVA_HOME to a Gradle-compatible JDK.' }
    Set-LabEnv JAVA_HOME $jdk
    Set-LabEnv ANDROID_HOME $sdk
    Set-LabEnv ANDROID_SDK_ROOT $sdk
    $preparedAvds = Join-Path $runtime 'avd'
    if (-not $AvdHome -and (Test-Path -LiteralPath (Join-Path $preparedAvds "$Avd.ini"))) { $AvdHome = $preparedAvds }
    if ($AvdHome) { Set-LabEnv ANDROID_AVD_HOME (Resolve-Path -LiteralPath $AvdHome).Path }
}

function Invoke-AndroidLint([string]$Gradle) {
    # Flutter can regenerate these paths with an unescaped drive colon.
    $properties = Join-Path $android 'local.properties'
    $contents = [IO.File]::ReadAllText($properties)
    $escaped = $contents -replace '(?m)^((?:sdk\.dir|flutter\.sdk)=[A-Za-z]):', '$1\:'
    if ($escaped -ne $contents) { [IO.File]::WriteAllText($properties, $escaped) }
    try {
        Invoke-LabCommand $android $Gradle @(':app:lintAnalyzeDebug', '--rerun', ':app:lintReportDebug', '--rerun', ':app:lintDebug')
    } finally {
        if ($escaped -ne $contents -and [IO.File]::ReadAllText($properties) -ceq $escaped) {
            [IO.File]::WriteAllText($properties, $contents)
        }
    }
}

function Get-AvdSerial {
    $devices = @(& $adb devices | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$') { $Matches[1] }
    })
    if ($devices.Count -ne 1 -or $devices[0] -notmatch '^emulator-\d+$') { return }
    $name = @((Invoke-Captured $adb @('-s', $devices[0], 'emu', 'avd', 'name')).stdout)
    if ($name.Count -and $name[0].Trim() -eq $Avd) { return $devices[0] }
}

function Start-LabEmulator {
    Set-AndroidTools
    Require-Tool $emulator 'Install Android Emulator in the SDK.'
    if ($Profile -ne 'Synthetic') { Block 'Authenticated Android needs a device-trusted HTTPS API and Auth endpoint.' }
    if ($Avd -notmatch '^[A-Za-z0-9_.-]+$' -or $Avd -cnotin @(& $emulator -list-avds)) {
        Block 'Select an existing disposable Android AVD with -Avd and, if needed, -AvdHome.'
    }
    $process = $null
    $serial = Get-AvdSerial
    if (-not $serial) {
        $connected = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_.Trim() })
        if ($connected.Count) { Block 'Disconnect other Android targets before starting the lab AVD.' }
        $options = @('-avd', $Avd, '-no-snapshot-save')
        if ($Headless) { $options += @('-no-window', '-no-audio') }
        $launch = @{
            FilePath = $emulator; ArgumentList = $options; PassThru = $true
            WindowStyle = $(if ($Headless) { 'Hidden' } else { 'Normal' })
            RedirectStandardOutput = (Join-Path $runtime 'emulator.out.log')
            RedirectStandardError = (Join-Path $runtime 'emulator.err.log')
        }
        $process = Start-Process @launch
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(240)
    do {
        $serial = Get-AvdSerial
        $booted = $serial -and ((Invoke-Captured $adb @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')).stdout -join '').Trim() -eq '1'
        if ($booted) { break }
        if ($process -and $process.HasExited -and -not $serial) { Fail 'Emulator exited. Check the ignored emulator logs.' }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $booted) { Block 'The selected AVD did not finish booting within four minutes.' }
    Write-Host "PASS Emulator $Avd ready ($serial)"
    if ($InstallMock) {
        $response = Read-Http "$mockUrl/v1/contents"
        if (-not $response -or $response.Status -ne 401) { Block 'Start the Synthetic profile before installing its mock app.' }
        Set-LabEnv ITDA_UPLOAD_MODE 'mock'
        Set-LabEnv ITDA_API_BASE_URL 'http://10.0.2.2:8782'
        Set-LabEnv ITDA_SUPABASE_URL 'http://10.0.2.2:8782'
        Set-LabEnv ITDA_SUPABASE_PUBLISHABLE_KEY 'sb_publishable_itda_mock'
        Invoke-LabCommand $mobile $flutter @('build', 'apk', '--debug', '--no-pub')
        $apk = Join-Path $mobile 'build\app\outputs\flutter-apk\app-debug.apk'
        Invoke-LabCommand $mobile $adb @('-s', $serial, 'install', '-r', $apk)
        Invoke-LabCommand $mobile $adb @('-s', $serial, 'shell', 'am', 'start', '-n', 'com.itda.itda_mobile/.MainActivity')
    }
}

function Test-IsolatedDatabase([string]$Project) {
    # Use the disposable volume prepared by the CLI and its matching image.
    $volume = 'supabase_db_' + $Project
    $inspection = Invoke-Captured $docker @('volume', 'inspect', $volume)
    if ($inspection.code) { Block 'The lab migration volume is unavailable. Run DatabaseStart first.' }
    $active = Invoke-Captured $docker @('ps', '--filter', "volume=$volume", '--format', '{{.Names}}')
    if ($active.code -or $active.stdout) { Block 'Stop the disposable stack before testing its volume in isolation.' }
    $name = "$Project-sql"
    $image = 'public.ecr.aws/supabase/postgres:17.6.1.171'
    $settings = @('run', '-d', '--rm', '--pull', 'never', '--name', $name, '--network', 'none',
                  '--mount', "type=volume,source=$volume,target=/var/lib/postgresql/data", $image)
    if (Invoke-Quiet $docker $settings) { Block "Could not start the disposable SQL test container with $image." }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $ready = (Invoke-Quiet $docker @('exec', $name, 'pg_isready', '-U', 'postgres', '-d', 'postgres', '-q')) -eq 0
            if (-not $ready) { Start-Sleep -Seconds 1 }
        } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)
        if (-not $ready) { Block 'The network-isolated PostgreSQL container did not become ready.' }
        $sql = "select version from supabase_migrations.schema_migrations order by version; select count(*) from storage.buckets where id='content-assets' and public=false;"
        $client = @('psql', '-XqAt', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')
        $facts = Invoke-Captured $docker (@('exec', $name) + $client + @('-c', $sql))
        if ($facts.code -or '202611090001' -notin $facts.stdout -or '202611090002' -notin $facts.stdout -or
            @($facts.stdout)[-1] -ne '1') { Fail 'Expected migrations and the private content-assets bucket.' }
        $test = Join-Path $dbWorkdir 'supabase\tests\database\foundation.test.sql'
        $command = @('exec', '-i', $name) + $client
        $tap = Get-Content -LiteralPath $test -Raw -Encoding UTF8 | & $docker @command
        $planned = $tap | Where-Object { $_ -match '^1\.\.\d+$' } | Select-Object -First 1
        $passed = @($tap | Where-Object { $_ -match '^ok \d+' }).Count
        if ($LASTEXITCODE -or -not $planned -or $planned -ne "1..$passed" -or ($tap -match '^not ok ')) {
            $tap | Where-Object { $_ -match '^not ok ' } | Write-Host
            Fail 'The isolated PostgreSQL pgTAP suite failed.'
        }
        Write-Host "PASS $passed pgTAP assertions, both migrations, and private content-assets on the isolated volume."
    } finally {
        if (Invoke-Quiet $docker @('stop', $name)) { Fail 'Could not stop the isolated SQL test container.' }
    }
}

function Stop-LabDatabase {
    if (Invoke-Quiet $supabase @('stop', '--workdir', $dbWorkdir)) {
        Fail 'Could not stop the disposable Supabase stack. Retry DatabaseStop for the lab workdir.'
    }
}

function Invoke-DatabaseAction {
    if ($Profile -ne 'Local') { Block 'Database commands require -Profile Local.' }
    $config = Join-Path $dbWorkdir 'supabase\config.toml'
    if ($Action -eq 'DatabaseStop' -and -not (Test-Path -LiteralPath $config)) {
        Write-Host 'PASS No disposable database has been created by this lab.'
        return
    }
    Require-Tool $docker 'Install Docker Desktop and start the local Linux engine.'
    Use-LocalDocker
    if ((Get-LocalDockerEngine) -ne 'linux') { Block 'Start the Docker Desktop Linux engine.' }
    if ($Action -ne 'DatabaseStart' -and -not (Test-Path -LiteralPath $config)) { Block 'Run DatabaseStart first.' }
    if ($Action -eq 'DatabaseStart') {
        if (-not (Test-Path -LiteralPath $config)) {
            Require-Tool $supabase 'Install Supabase CLI or set ITDA_LAB_SUPABASE_CLI to the local CLI executable.'
            $copy = Join-Path $dbWorkdir 'supabase'
            New-Item -ItemType Directory -Path $copy -Force | Out-Null
            foreach ($name in @('migrations', 'tests')) { Copy-Item -LiteralPath (Join-Path $root "supabase\$name") -Destination $copy -Recurse }
            $toml = Get-Content -LiteralPath (Join-Path $root 'supabase\config.toml') -Raw
            $id = 'itda-lab-' + ([guid]::NewGuid().ToString('N')).Substring(0, 8)
            $toml = $toml -replace '(?m)^project_id = ".*"\r?$', ('project_id = "' + $id + '"')
            $toml = $toml -replace '(?m)^(port|shadow_port) = 5432([0-3])\r?$', '$1 = 5542$2'
            $newline = [Environment]::NewLine
            $toml += $newline + "[local_smtp]${newline}enabled = false${newline}${newline}[edge_runtime]${newline}enabled = false"
            Set-Content -LiteralPath $config -Value $toml -Encoding Ascii
        }
    }
    $project = Select-String -LiteralPath $config -Pattern '^project_id = "(itda-lab-[a-f0-9]{8})"$'
    if (-not $project) { Fail 'The disposable Supabase workdir has an unexpected project ID.' }
    $network = $project.Matches[0].Groups[1].Value
    if ($Action -eq 'DatabaseTest' -and $Isolated) {
        Test-IsolatedDatabase $network
        return
    }
    Require-Tool $supabase 'Install Supabase CLI or set ITDA_LAB_SUPABASE_CLI to the local CLI executable.'
    if ($Action -eq 'DatabaseStart') {
        $inspection = Invoke-Captured $docker @('network', 'inspect', $network)
        if ($inspection.code) {
            & $docker network create --driver bridge --opt 'com.docker.network.bridge.host_binding_ipv4=127.0.0.1' $network | Out-Null
            if ($LASTEXITCODE) { Block 'Could not create the disposable loopback Docker network.' }
        } else {
            $binding = ($inspection.stdout | ConvertFrom-Json)[0].Options.'com.docker.network.bridge.host_binding_ipv4'
            if ($binding -ne '127.0.0.1') { Block 'The disposable Docker network must bind published ports to loopback.' }
        }
        $running = Invoke-Captured $docker @('ps', '--filter', "network=$network", '--format', '{{.Names}}')
        if ($running.code) { Block 'Could not inspect the disposable Docker network.' }
        if (-not $running.stdout) {
            foreach ($port in @(55420, 55421, 55422, 55423)) { Assert-FreePort $port }
        }
        # CLI startup prints connection credentials. Discard both streams.
        if (Invoke-Quiet $supabase @('start', '--workdir', $dbWorkdir, '--network-id', $network)) {
            Stop-LabDatabase
            Block 'The disposable Supabase stack failed to start. Check local Docker, CLI, images, and ports.'
        }
        $containers = & $docker ps --filter "network=$network" --format '{{.Ports}}'
        $published = [regex]::Matches(($containers -join ', '), '([^\s,]+):\d+->')
        $foreign = $published | Where-Object { $_.Groups[1].Value -notin @('127.0.0.1', '[::1]') }
        if ($LASTEXITCODE -or -not $published.Count -or $foreign) {
            Stop-LabDatabase
            Block 'Could not verify loopback-only Docker port bindings.'
        }
        $reply = Read-Http ($targets.local.auth_url + '/auth/v1/.well-known/jwks.json')
        if (-not $reply -or $reply.Status -ne 200) {
            Stop-LabDatabase
            Block 'The disposable Auth discovery endpoint is unavailable.'
        }
        Write-Host 'PASS Disposable Supabase started on the lab ports.'
    } elseif ($Action -eq 'DatabaseTest') {
        Invoke-LabCommand $root $supabase @('test', 'db', '--workdir', $dbWorkdir)
        Invoke-LabCommand $root $supabase @('db', 'lint', '--local', '--level', 'error', '--fail-on', 'error', '--workdir', $dbWorkdir)
    } else {
        Stop-LabDatabase
        Write-Host 'PASS Disposable Supabase stopped. Local volumes retained.'
    }
}

try {
    if (Test-Path -LiteralPath (Join-Path $android 'local.properties')) {
        foreach ($entry in Get-Content -LiteralPath (Join-Path $android 'local.properties')) {
            if ($entry -match '^(flutter\.sdk|sdk\.dir)=(.+)$') {
                $androidProperties[$Matches[1]] = $Matches[2].Replace('\:', ':').Replace('\\', '\')
            }
        }
    }
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $androidProperties['sdk.dir'] }
    $flutterBin = if ($androidProperties['flutter.sdk']) { Join-Path $androidProperties['flutter.sdk'] 'bin' }
    $flutter = Find-Executable 'flutter.bat' $(if ($flutterBin) { Join-Path $flutterBin 'flutter.bat' })
    $dart = Find-Executable 'dart.bat' $(if ($flutter) { Join-Path (Split-Path $flutter) 'dart.bat' })
    $adb = Find-Executable 'adb.exe' $(if ($sdk) { Join-Path $sdk 'platform-tools\adb.exe' })
    $emulator = Find-Executable 'emulator.exe' $(if ($sdk) { Join-Path $sdk 'emulator\emulator.exe' })
    $jdk = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { Join-Path $env:ProgramFiles 'Android\Android Studio\jbr' }
    $uv = Find-Executable 'uv.exe'
    $node = Find-Executable 'node.exe'
    $npm = Find-Executable 'npm.cmd'
    $docker = Find-Executable 'docker.exe'
    $supabase = Find-Executable 'supabase.exe' @($env:ITDA_LAB_SUPABASE_CLI)
    $privateSettings = if ($Action -in @('Start', 'Preflight', 'Smoke')) { Get-PrivateSettings } else { @{} }
    Clear-LabEnv
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    if ($Action -in @('Start', 'Stop')) {
        $lock = Open-LabLock 'apps'
        $state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }
        $owned = @($state.processes | Where-Object { $_ -and (Get-OwnedProcess $_) })
    }
    if ($Action -in @('DatabaseStart', 'DatabaseTest', 'DatabaseStop')) { $lock = Open-LabLock 'database' }
    if ($Action -in @('Start', 'Emulator', 'DatabaseStart')) {
        Add-Type -AssemblyName System.Net.Http
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseProxy = $false
        $http = [Net.Http.HttpClient]::new($handler)
        $http.Timeout = [TimeSpan]::FromSeconds(10)
    }

    switch ($Action) {
        'Check' {
            $deps = [ordered]@{
                Git = (Find-Executable 'git.exe'); uv = $uv; Node = $node; npm = $npm
                Flutter = $flutter; Dart = $dart; JDK = (Test-Path -LiteralPath (Join-Path $jdk 'bin\java.exe'))
                adb = $adb; Emulator = $emulator
            }
            foreach ($dependency in $deps.GetEnumerator()) {
                if ($dependency.Value) { Write-Host "PASS $($dependency.Key)" }
                else { Write-Host "BLOCKED $($dependency.Key)"; $exitCode = 2 }
            }
            if (Test-Path -LiteralPath $labPython -PathType Leaf) {
                Require-LabPython
                Write-Host "PASS $(& $labPython --version) (locked lab environment)"
            } else { Write-Host 'BLOCKED Lab Python. Run Setup.'; $exitCode = 2 }
            Use-LocalDocker
            $engine = Get-LocalDockerEngine
            if ($supabase -and $engine -eq 'linux') { Write-Host 'PASS Optional Supabase CLI and Docker Linux engine' }
            else {
                Write-Host 'BLOCKED Optional local database requires Supabase CLI and Docker Linux engine.'
                if ($Profile -eq 'Local') { $exitCode = 2 }
            }
        }
        'Setup' {
            Require-Tool $uv 'Install uv.'
            Require-Tool $npm 'Install supported Node.js and npm.'
            Set-LabEnv UV_PROJECT_ENVIRONMENT $venv
            $options = @('sync', '--locked', '--group', 'dev')
            if ($Python) { $options += @('--python', $Python) }
            if ($Offline) { $options += '--offline' }
            Invoke-LabCommand $backend $uv $options
            if (-not (Test-Path -LiteralPath (Join-Path $web 'node_modules\next\dist\bin\next'))) {
                $options = @('ci')
                if ($Offline) { $options += '--offline' }
                Invoke-LabCommand $web $npm $options
            }
        }
        'Start' { Start-LabServices $privateSettings $state $owned }
        'Stop' { Stop-OwnedServices $owned; Write-Host 'PASS No owned app services remain.' }
        { $_ -in @('Preflight', 'Smoke') } {
            Require-LabPython
            foreach ($entry in $privateSettings.GetEnumerator()) {
                if ($entry.Key -notmatch '_(DATABASE_URL|SYNC_CURSOR_SECRET|JWT_SECRET|SERVICE_ROLE_KEY)$') {
                    Set-LabEnv $entry.Key $entry.Value
                }
            }
            if ($flutter) { Set-LabEnv PATH ((Split-Path $flutter) + ';' + $env:PATH) }
            if ($sdk) { Set-LabEnv ANDROID_HOME $sdk }
            if (Test-Path -LiteralPath $jdk) { Set-LabEnv JAVA_HOME $jdk }
            if ($supabase) { Set-LabEnv PATH ((Split-Path $supabase) + ';' + $env:PATH) }
            $options = @((Join-Path $PSScriptRoot ($Action.ToLowerInvariant() + '.py')), '--profile', $harnessProfile)
            if ($RestartCheck -and $Action -eq 'Smoke') { $options += '--restart-check' }
            & $labPython @options
            $exitCode = $LASTEXITCODE
        }
        'Contract' {
            Require-LabPython
            Invoke-LabCommand $backend $labPython @('-m', 'pytest')
            Invoke-LabCommand $backend $labPython @('-m', 'app.contract_tools', '--check')
            Invoke-LabCommand $root $labPython @('supabase/verify_contract.py')
            if ($WebPreview) { Set-LabEnv ITDA_I1_WEB_PREVIEW_URL $webUrl }
            Invoke-LabCommand $backend $labPython @('-m', 'pytest', '../../tools/integration')
        }
        'Web' {
            Require-Tool $npm 'Install supported Node.js and npm.'
            Assert-WebEnvironment
            Set-LabEnv ITDA_DATA_MODE 'fixture'
            Invoke-LabCommand $web $npm @('test')
            Invoke-LabCommand $web $npm @('run', 'typecheck')
            Invoke-LabCommand $web $npm @('run', 'build')
        }
        'Flutter' {
            Require-Tool $flutter 'Install Flutter or configure flutter.sdk.'
            Require-Tool $dart 'Install the Dart SDK bundled with Flutter.'
            $options = @('pub', 'get', '--enforce-lockfile')
            if ($Offline) { $options += '--offline' }
            Invoke-LabCommand $mobile $flutter $options
            Invoke-LabCommand $mobile $dart @('run', 'tool/sync_fixtures.dart', '--check')
            Invoke-LabCommand $mobile $flutter @('analyze', '--no-pub')
            Invoke-LabCommand $mobile $flutter @('test', '--no-pub')
        }
        'Android' {
            Set-AndroidTools
            Set-LabEnv ITDA_UPLOAD_MODE 'disabled'
            $gradle = Join-Path $android 'gradlew.bat'
            Require-Tool (Find-Executable 'gradlew.bat' @($gradle)) 'Run the Android bootstrap described in the mobile README.'
            Invoke-LabCommand $android $gradle @(':app:assembleDebug', ':app:assembleDebugAndroidTest')
            Invoke-AndroidLint $gradle
            if ($Instrumented) {
                if (-not (Get-AvdSerial)) { Block 'Boot and unlock the selected disposable AVD with no other connected targets.' }
                Invoke-LabCommand $android $gradle @(':app:connectedDebugAndroidTest')
            }
        }
        'Emulator' { Start-LabEmulator }
        { $_ -in @('DatabaseStart', 'DatabaseTest', 'DatabaseStop') } { Invoke-DatabaseAction }
    }
} catch {
    $message = $_.Exception.Message
    if ($message.StartsWith('BLOCKED ')) { Write-Host $message; $exitCode = 2 }
    elseif ($message.StartsWith('FAIL ')) { Write-Host $message; $exitCode = 1 }
    else {
        Write-Host "FAIL $Action ($($_.Exception.GetType().Name), script line $($_.InvocationInfo.ScriptLineNumber))."
        $exitCode = 1
    }
} finally {
    if ($http) { $http.Dispose() }
    if ($lock) { $lock.Dispose() }
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        Set-LabEnv $entry.Key $entry.Value
    }
}
exit $exitCode
