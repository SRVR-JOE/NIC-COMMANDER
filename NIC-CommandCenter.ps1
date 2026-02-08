<#
.SYNOPSIS
    NIC Command Center v2.0 - Network Configurator + Diagnostics
.DESCRIPTION
    3-tab web UI: Quick Config, Advanced Settings, Diagnostics
    Auto-detects adapters. All changes applied live via PowerShell.
.NOTES
    Right-click PowerShell > Run as Administrator > .\NIC-CommandCenter.ps1
#>

#Requires -RunAsAdministrator

$Port = 8977
$Url = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Url)
try { $listener.Start() } catch {
    Write-Host "ERROR: Could not start on port $Port. Run as Admin." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
Write-Host "`n  NIC COMMAND CENTER v2.0" -ForegroundColor Cyan
Write-Host "  $Url" -ForegroundColor Green
Write-Host "  Ctrl+C to stop`n" -ForegroundColor Yellow
Start-Process $Url

function Get-NicDataJson {
    $adapters = Get-NetAdapter | Sort-Object InterfaceIndex
    $results = @()
    foreach ($a in $adapters) {
        $alias = $a.Name
        $ipConfig = Get-NetIPConfiguration -InterfaceAlias $alias -EA SilentlyContinue
        $ipAddr = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -EA SilentlyContinue | Select -First 1
        $ipv6Addr = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv6 -EA SilentlyContinue | Where { $_.PrefixOrigin -ne 'WellKnown' } | Select -First 1
        $dhcpSt = Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -EA SilentlyContinue
        $dnsS = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -EA SilentlyContinue).ServerAddresses
        $dnsC = Get-DnsClient -InterfaceAlias $alias -EA SilentlyContinue
        $ipIf = Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -EA SilentlyContinue
        $adv = Get-NetAdapterAdvancedProperty -Name $alias -EA SilentlyContinue
        $jumbo = ($adv | Where { $_.RegistryKeyword -eq '*JumboPacket' }).DisplayValue
        $vlan = ($adv | Where { $_.RegistryKeyword -eq 'VlanID' }).DisplayValue
        $wol = ($adv | Where { $_.RegistryKeyword -like '*WakeOnMagicPacket*' }).DisplayValue
        $rss = ($adv | Where { $_.RegistryKeyword -eq '*RSS' }).DisplayValue
        $spd = ($adv | Where { $_.RegistryKeyword -eq '*SpeedDuplex' }).DisplayValue
        $ipv6B = Get-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -EA SilentlyContinue
        $gw = ''; if ($ipConfig.IPv4DefaultGateway) { $gw = $ipConfig.IPv4DefaultGateway.NextHop }
        $prefix = 24; $mask = '255.255.255.0'
        if ($ipAddr) { $prefix = $ipAddr.PrefixLength; $bits = ('1' * $prefix).PadRight(32,'0')
            $mask = "{0}.{1}.{2}.{3}" -f [Convert]::ToInt32($bits.Substring(0,8),2),[Convert]::ToInt32($bits.Substring(8,8),2),[Convert]::ToInt32($bits.Substring(16,8),2),[Convert]::ToInt32($bits.Substring(24,8),2) }
        $mtu = ''; if ($ipIf) { $mtu = $ipIf.NlMtu.ToString() }
        $met = ''; if ($ipIf -and -not $ipIf.AutomaticMetric) { $met = $ipIf.InterfaceMetric.ToString() }
        $results += @{
            ifIndex=$a.InterfaceIndex;name=$alias;hw=$a.InterfaceDescription;mac=$a.MacAddress;status=$a.Status.ToString();enabled=($a.Status -ne 'Disabled');linkSpeed=$a.LinkSpeed
            dhcp=($dhcpSt.Dhcp -eq 'Enabled');ip=if($ipAddr){$ipAddr.IPAddress}else{''};subnet=$mask;prefix=$prefix;gateway=$gw
            dns1=if($dnsS.Count -ge 1){$dnsS[0]}else{''};dns2=if($dnsS.Count -ge 2){$dnsS[1]}else{''}
            mtu=$mtu;metric=$met;vlan=if($vlan){$vlan}else{''};jumbo=($jumbo -and $jumbo -ne 'Disabled' -and $jumbo -ne '1514')
            wol=($wol -eq 'Enabled');rss=($rss -eq 'Enabled');qos=$false
            dnsSuffix=if($dnsC){$dnsC.ConnectionSpecificSuffix}else{''};registerDns=if($dnsC){$dnsC.RegisterThisConnectionsAddress}else{$true}
            ipv6=if($ipv6B){$ipv6B.Enabled}else{$false};ipv6addr=if($ipv6Addr){$ipv6Addr.IPAddress}else{''};ipv6prefix=if($ipv6Addr){$ipv6Addr.PrefixLength.ToString()}else{'64'}
            speedDuplex=if($spd){$spd}else{'Auto Negotiation'};netbios='Default';arp=$false;lmhosts=$true
        }
    }
    return ($results | ConvertTo-Json -Depth 5 -Compress)
}

function Apply-NicConfig { param([string]$JsonBody)
    $config = $JsonBody | ConvertFrom-Json; $results = @()
    foreach ($nic in $config) { try {
        $alias = $nic.originalName; $newName = $nic.name
        if ($alias -ne $newName) { Rename-NetAdapter -Name $alias -NewName $newName -EA Stop; $alias = $newName }
        if (-not $nic.enabled) { Disable-NetAdapter -Name $alias -Confirm:$false -EA Stop; $results += @{name=$alias;success=$true;message="Disabled"}; continue }
        else { $cur = Get-NetAdapter -Name $alias -EA SilentlyContinue; if ($cur.Status -eq 'Disabled') { Enable-NetAdapter -Name $alias -Confirm:$false -EA Stop; Start-Sleep 2 } }
        if ($nic.dhcp) { Set-NetIPInterface -InterfaceAlias $alias -Dhcp Enabled -EA SilentlyContinue; Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -EA SilentlyContinue }
        else { Remove-NetIPAddress -InterfaceAlias $alias -Confirm:$false -EA SilentlyContinue; Remove-NetRoute -InterfaceAlias $alias -Confirm:$false -EA SilentlyContinue
            if ($nic.ip -and $nic.subnet) { $p=@{InterfaceAlias=$alias;IPAddress=$nic.ip;PrefixLength=$nic.prefix;AddressFamily='IPv4'}; if($nic.gateway){$p['DefaultGateway']=$nic.gateway}; New-NetIPAddress @p -EA Stop | Out-Null }
            $dns=@();if($nic.dns1){$dns+=$nic.dns1};if($nic.dns2){$dns+=$nic.dns2}; if($dns.Count -gt 0){Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dns -EA SilentlyContinue} }
        if($nic.metric -and $nic.metric -ne ''){Set-NetIPInterface -InterfaceAlias $alias -InterfaceMetric ([int]$nic.metric) -AutomaticMetric Disabled -EA SilentlyContinue}
        else{Set-NetIPInterface -InterfaceAlias $alias -AutomaticMetric Enabled -EA SilentlyContinue}
        if($nic.dnsSuffix -ne $null){Set-DnsClient -InterfaceAlias $alias -ConnectionSpecificSuffix $nic.dnsSuffix -RegisterThisConnectionsAddress $nic.registerDns -EA SilentlyContinue}
        if($nic.ipv6){Enable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -EA SilentlyContinue}else{Disable-NetAdapterBinding -Name $alias -ComponentID ms_tcpip6 -EA SilentlyContinue}
        $results += @{name=$alias;success=$true;message="Configured OK"}
    } catch { $results += @{name=$alias;success=$false;message=$_.Exception.Message} } }
    return ($results | ConvertTo-Json -Depth 3 -Compress)
}

function Run-Ping { param([string]$J); $d=$J|ConvertFrom-Json; try{$o=ping -n $d.count -w 2000 $d.target 2>&1|Out-String;return(@{success=$true;output=$o}|ConvertTo-Json -Compress)}catch{return(@{success=$false;output=$_.Exception.Message}|ConvertTo-Json -Compress)} }
function Run-SinglePing { param([string]$J); $d=$J|ConvertFrom-Json; try{$r=Test-Connection -ComputerName $d.target -Count 1 -EA Stop;return(@{success=$true;ms=$r.ResponseTime;target=$d.target}|ConvertTo-Json -Compress)}catch{return(@{success=$false;ms=-1;target=$d.target}|ConvertTo-Json -Compress)} }
function Run-Traceroute { param([string]$J); $d=$J|ConvertFrom-Json; try{$o=tracert -d -w 2000 $d.target 2>&1|Out-String;return(@{success=$true;output=$o}|ConvertTo-Json -Compress)}catch{return(@{success=$false;output=$_.Exception.Message}|ConvertTo-Json -Compress)} }
function Run-DnsLookup { param([string]$J); $d=$J|ConvertFrom-Json; try{$o=nslookup -type=$($d.type) $d.target 2>&1|Out-String;return(@{success=$true;output=$o}|ConvertTo-Json -Compress)}catch{return(@{success=$false;output=$_.Exception.Message}|ConvertTo-Json -Compress)} }
function Run-PortScan { param([string]$J); $d=$J|ConvertFrom-Json; $res=@()
    foreach($port in ($d.ports -split ',')){$p=$port.Trim();if(-not $p){continue};try{$tcp=New-Object System.Net.Sockets.TcpClient;$c=$tcp.BeginConnect($d.target,[int]$p,$null,$null);$w=$c.AsyncWaitHandle.WaitOne(1500,$false)
    if($w -and $tcp.Connected){$res+=@{port=[int]$p;state='OPEN'};$tcp.EndConnect($c)}else{$res+=@{port=[int]$p;state='CLOSED'}};$tcp.Close()}catch{$res+=@{port=[int]$p;state='CLOSED'}}}
    return(@{success=$true;results=$res}|ConvertTo-Json -Depth 3 -Compress) }
function Run-ArpTable { try{$o=arp -a 2>&1|Out-String;return(@{success=$true;output=$o}|ConvertTo-Json -Compress)}catch{return(@{success=$false;output=$_.Exception.Message}|ConvertTo-Json -Compress)} }
function Run-Command { param([string]$J); $d=$J|ConvertFrom-Json; try{$o=switch($d.cmd){'ipconfig'{ipconfig 2>&1|Out-String}'ipconfig_all'{ipconfig /all 2>&1|Out-String}'route_print'{route print 2>&1|Out-String}'netstat'{netstat -an 2>&1|Out-String}'flushdns'{ipconfig /flushdns 2>&1|Out-String}'release'{ipconfig /release 2>&1|Out-String}'renew'{ipconfig /renew 2>&1|Out-String}'arp_flush'{netsh interface ip delete arpcache 2>&1|Out-String}default{"Unknown: $($d.cmd)"}};return(@{success=$true;output=$o}|ConvertTo-Json -Compress)}catch{return(@{success=$false;output=$_.Exception.Message}|ConvertTo-Json -Compress)} }

function Send-Resp { param($r,$j,$ct="application/json; charset=utf-8"); $r.ContentType=$ct;$b=[System.Text.Encoding]::UTF8.GetBytes($j);$r.ContentLength64=$b.Length;$r.OutputStream.Write($b,0,$b.Length) }
function Read-Body { param($r); $rd=New-Object System.IO.StreamReader($r.InputStream,$r.ContentEncoding);$b=$rd.ReadToEnd();$rd.Close();return $b }


$HTML = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NIC Command Center</title>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600;700&family=Outfit:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg-deep:#0a0c10;--bg-panel:#111419;--bg-card:#161a22;--bg-input:#1c2028;
  --border:#252a35;--border-light:#2f3645;
  --text-primary:#e8eaed;--text-secondary:#8b92a5;--text-muted:#5a6178;
  --accent:#3b82f6;--accent-glow:rgba(59,130,246,0.15);--accent-bright:#60a5fa;
  --green:#22c55e;--green-glow:rgba(34,197,94,0.12);
  --amber:#f59e0b;--amber-glow:rgba(245,158,11,0.12);
  --red:#ef4444;--red-glow:rgba(239,68,68,0.12);
  --cyan:#06b6d4;--purple:#a855f7;--pink:#ec4899;
  --radius:8px;--radius-lg:12px;
}
html{font-size:13px}
body{font-family:'Outfit',sans-serif;background:var(--bg-deep);color:var(--text-primary);min-height:100vh;overflow-x:hidden;padding-bottom:44px}
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--border-light);border-radius:3px}

.header{display:flex;align-items:center;justify-content:space-between;padding:12px 24px;background:var(--bg-panel);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100}
.header-left{display:flex;align-items:center;gap:14px}
.logo{width:34px;height:34px;background:linear-gradient(135deg,var(--accent),var(--cyan));border-radius:9px;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:800;color:#fff;font-family:'JetBrains Mono'}
.app-title{font-size:16px;font-weight:700;letter-spacing:-.5px}
.app-title span{color:var(--accent-bright);font-family:'JetBrains Mono';font-weight:600}
.app-subtitle{font-size:9.5px;color:var(--text-muted);font-family:'JetBrains Mono';letter-spacing:1px;text-transform:uppercase}
.header-right{display:flex;align-items:center;gap:8px}

.btn{font-family:'Outfit';padding:7px 14px;border-radius:var(--radius);border:1px solid var(--border);background:var(--bg-card);color:var(--text-primary);cursor:pointer;font-size:11.5px;font-weight:500;transition:all .15s;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
.btn:hover{border-color:var(--border-light);background:var(--bg-input)}
.btn-primary{background:var(--accent);border-color:var(--accent);color:#fff;box-shadow:0 0 20px var(--accent-glow)}
.btn-primary:hover{background:var(--accent-bright)}
.btn-success{background:var(--green);border-color:var(--green);color:#fff;box-shadow:0 0 20px var(--green-glow)}
.btn-danger{background:transparent;border-color:var(--red);color:var(--red)}
.btn-danger:hover{background:var(--red);color:#fff}
.btn-sm{padding:4px 10px;font-size:10.5px}
.btn-icon{width:28px;height:28px;padding:0;display:flex;align-items:center;justify-content:center;border-radius:var(--radius)}

.tab-bar{display:flex;align-items:center;gap:0;padding:0 24px;background:var(--bg-panel);border-bottom:1px solid var(--border)}
.tab-btn{padding:11px 22px;font-family:'Outfit';font-size:12.5px;font-weight:500;color:var(--text-muted);border:none;background:none;cursor:pointer;position:relative;transition:color .2s;display:flex;align-items:center;gap:7px}
.tab-btn:hover{color:var(--text-secondary)}
.tab-btn.active{color:var(--accent-bright);font-weight:600}
.tab-btn.active::after{content:'';position:absolute;bottom:-1px;left:8px;right:8px;height:2px;background:var(--accent);border-radius:2px 2px 0 0}
.tab-btn svg{width:15px;height:15px}
.tab-right{margin-left:auto;display:flex;align-items:center;gap:8px;padding:6px 0}
.tab-right label{font-size:10px;font-family:'JetBrains Mono';color:var(--text-muted);text-transform:uppercase;letter-spacing:1px}

select,input,textarea{font-family:'JetBrains Mono',monospace;font-size:12px;padding:6px 10px;border-radius:var(--radius);border:1px solid var(--border);background:var(--bg-input);color:var(--text-primary);outline:none;transition:border-color .2s;width:100%}
select:focus,input:focus,textarea:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}
select{cursor:pointer;appearance:none;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' fill='%238b92a5'%3E%3Cpath d='M6 8L1 3h10z'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center}
input:disabled{opacity:.35;cursor:not-allowed}

.page{display:none;padding:16px 24px;max-width:1920px;margin:0 auto}
.page.active{display:block}

/* SUMMARY */
.summary-strip{display:flex;gap:10px;margin-bottom:16px;flex-wrap:wrap}
.s-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:10px 16px;display:flex;align-items:center;gap:10px;flex:1;min-width:120px}
.s-num{font-family:'JetBrains Mono';font-size:24px;font-weight:700;line-height:1}
.s-label{font-size:10.5px;color:var(--text-muted);line-height:1.3}

/* QUICK TABLE */
.q-wrap{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden}
.q-table{width:100%;border-collapse:collapse}
.q-table thead th{font-family:'JetBrains Mono';font-size:10px;font-weight:500;text-transform:uppercase;letter-spacing:.7px;color:var(--text-muted);padding:10px 12px;text-align:left;background:var(--bg-panel);border-bottom:1px solid var(--border);white-space:nowrap}
.q-table tbody tr{transition:background .15s}
.q-table tbody tr:hover{background:rgba(59,130,246,0.03)}
.q-table tbody tr:not(:last-child) td{border-bottom:1px solid var(--border)}
.q-table td{padding:7px 12px;vertical-align:middle}
.q-table input{padding:5px 8px;font-size:11.5px}
.q-table input:disabled{background:transparent;border-color:transparent;opacity:.5}
.q-indicator{width:8px;height:8px;border-radius:50%;flex-shrink:0;display:inline-block;margin-right:8px}
.q-indicator.up{background:var(--green);box-shadow:0 0 6px var(--green)}
.q-indicator.disconnected{background:var(--amber);box-shadow:0 0 5px var(--amber)}
.q-indicator.down,.q-indicator.disabled{background:var(--text-muted)}
.q-name input{font-family:'Outfit'!important;font-weight:600;font-size:12.5px!important;background:transparent!important;border-color:transparent!important;padding:3px 6px!important;width:100%;min-width:100px}
.q-name input:hover{border-color:var(--border)!important}
.q-name input:focus{border-color:var(--accent)!important;background:var(--bg-input)!important}
.q-hw{font-family:'JetBrains Mono';font-size:8.5px;color:var(--text-muted);padding-left:22px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:240px}
.q-badge{font-family:'JetBrains Mono';font-size:9px;padding:2px 7px;border-radius:3px;white-space:nowrap;display:inline-block}
.q-badge.up{background:var(--green-glow);color:var(--green);border:1px solid rgba(34,197,94,0.15)}
.q-badge.down,.q-badge.disabled{background:rgba(90,97,120,0.12);color:var(--text-muted);border:1px solid rgba(90,97,120,0.15)}
.q-badge.disconnected{background:var(--amber-glow);color:var(--amber);border:1px solid rgba(245,158,11,0.15)}
.q-color{width:4px;border-radius:0 2px 2px 0}
.toggle{width:34px;height:18px;border-radius:9px;background:var(--border-light);cursor:pointer;position:relative;transition:all .2s;border:none;padding:0;flex-shrink:0}
.toggle.active{background:var(--accent)}
.toggle::after{content:'';position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:#fff;transition:transform .2s}
.toggle.active::after{transform:translateX(16px)}

/* ADVANCED CARDS */
.adv-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(400px,1fr));gap:14px}
.adv-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden;transition:all .3s;position:relative;animation:cardIn .4s ease both}
.adv-card:hover{border-color:var(--border-light);box-shadow:0 4px 20px rgba(0,0,0,.3)}
.adv-card.off{opacity:.4}
.adv-card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:var(--nic-color);opacity:.7}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes cardIn{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
.adv-header{display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid var(--border)}
.adv-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.adv-dot.up{background:var(--green);box-shadow:0 0 8px var(--green)}
.adv-dot.disconnected{background:var(--amber);box-shadow:0 0 6px var(--amber)}
.adv-dot.down,.adv-dot.disabled{background:var(--text-muted)}
.adv-title{font-size:13px;font-weight:600;flex:1}
.adv-sub{font-family:'JetBrains Mono';font-size:9.5px;color:var(--text-muted)}
.adv-body{padding:12px 14px;display:flex;flex-direction:column;gap:6px}
.adv-2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.adv-3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}
.field{display:flex;flex-direction:column;gap:3px}
.field-label{font-size:9.5px;font-family:'JetBrains Mono';color:var(--text-muted);text-transform:uppercase;letter-spacing:.5px}
.section-label{font-size:9.5px;font-family:'JetBrains Mono';color:var(--text-muted);text-transform:uppercase;letter-spacing:1px;padding:6px 0 2px;border-top:1px solid var(--border);margin-top:4px}
.section-label:first-child{border-top:none;margin-top:0}
.toggle-row{display:flex;align-items:center;justify-content:space-between;padding:3px 0}
.toggle-label{font-size:11.5px;color:var(--text-secondary)}
.adv-footer{display:flex;align-items:center;justify-content:space-between;padding:8px 14px;border-top:1px solid var(--border);background:rgba(0,0,0,.12)}
.adv-footer .ft{font-family:'JetBrains Mono';font-size:9.5px;color:var(--text-muted)}

/* ═══ DIAGNOSTICS PAGE ═══ */
.diag-layout{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media(max-width:1100px){.diag-layout{grid-template-columns:1fr}}
.diag-panel{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden}
.diag-panel-header{padding:12px 16px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:8px;background:var(--bg-panel)}
.diag-panel-header h4{font-size:12.5px;font-weight:600;flex:1}
.diag-panel-header svg{width:16px;height:16px;color:var(--accent-bright)}
.diag-panel-body{padding:14px 16px}
.diag-input-row{display:flex;gap:8px;margin-bottom:10px}
.diag-input-row input{flex:1}
.diag-output{background:var(--bg-deep);border:1px solid var(--border);border-radius:var(--radius);padding:10px 12px;font-family:'JetBrains Mono';font-size:11px;line-height:1.7;color:var(--text-secondary);min-height:140px;max-height:300px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.diag-output .ping-ok{color:var(--green)}
.diag-output .ping-fail{color:var(--red)}
.diag-output .ping-warn{color:var(--amber)}
.diag-output .ping-info{color:var(--accent-bright)}
.diag-output .hop{color:var(--cyan)}

/* PING MONITOR GRID */
.ping-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:8px;margin-top:10px}
.ping-target{background:var(--bg-input);border:1px solid var(--border);border-radius:var(--radius);padding:10px 12px;position:relative;overflow:hidden;transition:border-color .3s}
.ping-target.ok{border-color:rgba(34,197,94,0.3)}
.ping-target.fail{border-color:rgba(239,68,68,0.3)}
.ping-target.pending{border-color:rgba(245,158,11,0.3)}
.ping-target-name{font-size:11.5px;font-weight:600;margin-bottom:2px;display:flex;align-items:center;gap:6px}
.ping-target-addr{font-family:'JetBrains Mono';font-size:10px;color:var(--text-muted)}
.ping-target-status{font-family:'JetBrains Mono';font-size:20px;font-weight:700;margin-top:6px}
.ping-target-status.ok{color:var(--green)}
.ping-target-status.fail{color:var(--red)}
.ping-target-status.pending{color:var(--amber)}
.ping-target-bar{display:flex;gap:2px;margin-top:6px;height:16px;align-items:flex-end}
.ping-bar{width:4px;border-radius:2px;background:var(--border-light);transition:all .3s;min-height:2px}
.ping-bar.ok{background:var(--green)}
.ping-bar.fail{background:var(--red)}
.ping-bar.slow{background:var(--amber)}
.ping-dot{width:6px;height:6px;border-radius:50%;flex-shrink:0}
.ping-dot.ok{background:var(--green);box-shadow:0 0 4px var(--green)}
.ping-dot.fail{background:var(--red);box-shadow:0 0 4px var(--red)}
.ping-dot.pending{background:var(--amber)}
.ping-remove{position:absolute;top:6px;right:6px;background:none;border:none;color:var(--text-muted);cursor:pointer;font-size:14px;padding:2px;line-height:1}
.ping-remove:hover{color:var(--red)}
.ping-stats{font-family:'JetBrains Mono';font-size:9px;color:var(--text-muted);margin-top:4px;display:flex;gap:8px}

/* FULL WIDTH PANELS */
.diag-full{grid-column:1/-1}
.diag-add-row{display:flex;gap:8px;align-items:center}
.diag-add-row input{flex:1;max-width:260px}
.diag-add-row select{width:140px}

/* MODALS */
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);backdrop-filter:blur(4px);z-index:200;display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:opacity .3s}
.modal-overlay.show{opacity:1;pointer-events:all}
.modal{background:var(--bg-panel);border:1px solid var(--border);border-radius:var(--radius-lg);width:520px;max-width:92vw;max-height:80vh;overflow-y:auto;transform:translateY(20px);transition:transform .3s}
.modal-overlay.show .modal{transform:translateY(0)}
.modal-header{padding:18px 20px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.modal-header h3{font-size:15px;font-weight:600}
.modal-body{padding:18px 20px;display:flex;flex-direction:column;gap:10px}
.modal-footer{padding:14px 20px;border-top:1px solid var(--border);display:flex;justify-content:flex-end;gap:8px}
.profile-item{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;border:1px solid var(--border);border-radius:var(--radius);background:var(--bg-input);gap:10px}
.profile-item-name{font-family:'JetBrains Mono';font-size:12px;font-weight:500}
.profile-actions{display:flex;gap:4px}

.toast-container{position:fixed;bottom:52px;right:24px;z-index:300;display:flex;flex-direction:column;gap:8px}
.toast{padding:10px 16px;border-radius:var(--radius);background:var(--bg-panel);border:1px solid var(--border);font-size:11.5px;display:flex;align-items:center;gap:8px;animation:slideIn .3s ease;box-shadow:0 8px 32px rgba(0,0,0,.4)}
.toast.success{border-color:var(--green)}.toast.error{border-color:var(--red)}.toast.info{border-color:var(--accent)}
@keyframes slideIn{from{transform:translateX(100px);opacity:0}to{transform:translateX(0);opacity:1}}

.status-bar{padding:7px 24px;background:var(--bg-panel);border-top:1px solid var(--border);position:fixed;bottom:0;left:0;right:0;display:flex;align-items:center;justify-content:space-between;font-family:'JetBrains Mono';font-size:10px;color:var(--text-muted);z-index:100}
.status-left{display:flex;align-items:center;gap:16px}
.status-dot{width:6px;height:6px;border-radius:50%;display:inline-block;margin-right:4px;background:var(--green)}

@media(max-width:1000px){.adv-grid{grid-template-columns:1fr}.diag-layout{grid-template-columns:1fr}}
</style>
</head>
<body>

<div id="loadingOverlay" style="position:fixed;inset:0;background:#0a0c10;z-index:999;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;transition:opacity .5s"><div style="width:40px;height:40px;border:3px solid #252a35;border-top-color:#3b82f6;border-radius:50%;animation:spin 1s linear infinite"></div><div style="font-family:JetBrains Mono;font-size:12px;color:#5a6178">Detecting adapters...</div></div>
<div class="header">
  <div class="header-left">
    <div class="logo">NC</div>
    <div><div class="app-title">NIC <span>Command Center</span></div><div class="app-subtitle">Network Interface Configurator</div></div>
  </div>
  <div class="header-right">
    <button class="btn" onclick="toast('success','Refreshed');renderAll()">⟳ Refresh</button>
    <button class="btn btn-primary" onclick="applyAll()">⚡ Apply All</button>
  </div>
</div>

<div class="tab-bar">
  <button class="tab-btn active" data-tab="quick" onclick="switchTab('quick')">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>Quick Config</button>
  <button class="tab-btn" data-tab="advanced" onclick="switchTab('advanced')">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>Advanced</button>
  <button class="tab-btn" data-tab="diag" onclick="switchTab('diag')">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>Diagnostics</button>
  <div class="tab-right">
    <label>Profile</label>
    <select id="profileSelect" style="width:190px" onchange="loadProfile(this.value)"><option value="">— Select Profile —</option></select>
    <button class="btn btn-sm" onclick="showModal('saveProfileModal')">💾</button>
    <button class="btn btn-sm" onclick="showManageProfiles()">📁</button>
    <button class="btn btn-sm btn-success" onclick="executeProfile()">▶ Execute</button>
  </div>
</div>

<!-- ═══ QUICK CONFIG ═══ -->
<div class="page active" id="page-quick">
  <div class="summary-strip" id="summaryStrip"></div>
  <div class="q-wrap"><table class="q-table">
    <thead><tr><th style="width:4px;padding:0"></th><th>Adapter</th><th>Status</th><th>DHCP</th><th>IP Address</th><th>Subnet Mask</th><th>Gateway</th><th>DNS 1</th><th>DNS 2</th><th>Enable</th><th></th></tr></thead>
    <tbody id="qBody"></tbody>
  </table></div>
</div>

<!-- ═══ ADVANCED ═══ -->
<div class="page" id="page-advanced">
  <div class="adv-grid" id="advGrid"></div>
</div>

<!-- ═══ DIAGNOSTICS ═══ -->
<div class="page" id="page-diag">

  <!-- PING MONITOR -->
  <div class="diag-panel diag-full" style="margin-bottom:16px">
    <div class="diag-panel-header">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
      <h4>Ping Monitor</h4>
      <span style="font-family:'JetBrains Mono';font-size:10px;color:var(--text-muted)" id="monitorStatus">Stopped</span>
      <button class="btn btn-sm btn-success" id="monitorToggle" onclick="toggleMonitor()">▶ Start</button>
    </div>
    <div class="diag-panel-body">
      <div class="diag-add-row">
        <input type="text" id="monitorAddInput" placeholder="IP or hostname (e.g., 192.168.1.1)" onkeydown="if(event.key==='Enter')addMonitorTarget()">
        <input type="text" id="monitorAddLabel" placeholder="Label (optional)" style="max-width:160px" onkeydown="if(event.key==='Enter')addMonitorTarget()">
        <button class="btn btn-sm btn-primary" onclick="addMonitorTarget()">+ Add Target</button>
        <button class="btn btn-sm" onclick="addPresets()">+ Common Presets</button>
        <button class="btn btn-sm btn-danger" onclick="clearMonitor()">Clear All</button>
      </div>
      <div class="ping-grid" id="pingGrid"></div>
    </div>
  </div>

  <div class="diag-layout">
    <!-- PING -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>
        <h4>Ping</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row">
          <input type="text" id="pingInput" placeholder="IP or hostname" value="8.8.8.8" onkeydown="if(event.key==='Enter')runPing()">
          <input type="number" id="pingCount" value="4" min="1" max="50" style="width:60px" title="Count">
          <button class="btn btn-primary" onclick="runPing()">Ping</button>
        </div>
        <div class="diag-output" id="pingOutput">Ready. Enter a target and click Ping.</div>
      </div>
    </div>

    <!-- TRACEROUTE -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="2"/><path d="M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"/></svg>
        <h4>Traceroute</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row">
          <input type="text" id="traceInput" placeholder="IP or hostname" value="google.com" onkeydown="if(event.key==='Enter')runTrace()">
          <button class="btn btn-primary" onclick="runTrace()">Trace</button>
        </div>
        <div class="diag-output" id="traceOutput">Ready. Enter a target and click Trace.</div>
      </div>
    </div>

    <!-- DNS LOOKUP -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"/><circle cx="12" cy="10" r="3"/></svg>
        <h4>DNS Lookup</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row">
          <input type="text" id="dnsInput" placeholder="Hostname" value="google.com" onkeydown="if(event.key==='Enter')runDns()">
          <select id="dnsType" style="width:80px"><option>A</option><option>AAAA</option><option>MX</option><option>NS</option><option>CNAME</option><option>TXT</option><option>SOA</option><option>PTR</option></select>
          <button class="btn btn-primary" onclick="runDns()">Lookup</button>
        </div>
        <div class="diag-output" id="dnsOutput">Ready. Enter a hostname and click Lookup.</div>
      </div>
    </div>

    <!-- PORT CHECK -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/></svg>
        <h4>Port Check</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row">
          <input type="text" id="portHost" placeholder="IP or hostname" value="192.168.1.1" onkeydown="if(event.key==='Enter')runPort()">
          <input type="text" id="portNum" placeholder="Port(s)" value="80,443,22,3389" style="width:140px" onkeydown="if(event.key==='Enter')runPort()">
          <button class="btn btn-primary" onclick="runPort()">Scan</button>
        </div>
        <div class="diag-output" id="portOutput">Ready. Enter host and ports (comma-separated).</div>
      </div>
    </div>

    <!-- ARP TABLE -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
        <h4>ARP Table</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row">
          <button class="btn btn-primary" onclick="runArp()">Show ARP Table</button>
          <button class="btn" onclick="runCmd('arp_flush')">Flush ARP Cache</button>
        </div>
        <div class="diag-output" id="arpOutput">Click "Show ARP Table" to view cached addresses.</div>
      </div>
    </div>

    <!-- IPCONFIG / ROUTE -->
    <div class="diag-panel">
      <div class="diag-panel-header">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
        <h4>Quick Commands</h4>
      </div>
      <div class="diag-panel-body">
        <div class="diag-input-row" style="flex-wrap:wrap">
          <button class="btn btn-sm" onclick="runCmd('ipconfig')">ipconfig</button>
          <button class="btn btn-sm" onclick="runCmd('ipconfig /all')">ipconfig /all</button>
          <button class="btn btn-sm" onclick="runCmd('route print')">route print</button>
          <button class="btn btn-sm" onclick="runCmd('netstat')">netstat -an</button>
          <button class="btn btn-sm" onclick="runCmd('flushdns')">Flush DNS</button>
          <button class="btn btn-sm" onclick="runCmd('release')">DHCP Release</button>
          <button class="btn btn-sm" onclick="runCmd('renew')">DHCP Renew</button>
        </div>
        <div class="diag-output" id="cmdOutput">Select a command above to execute.</div>
      </div>
    </div>
  </div>
</div>

<div class="status-bar">
  <div class="status-left">
    <span><span class="status-dot"></span>Connected</span>
    <span id="nicCount">7 Adapters</span>
    <span>Refreshed: just now</span>
  </div>
  <span>NIC Command Center v2.0 · PowerShell Backend</span>
</div>

<!-- SAVE MODAL -->
<div class="modal-overlay" id="saveProfileModal">
  <div class="modal">
    <div class="modal-header"><h3>Save Profile</h3><button class="btn btn-icon" onclick="closeModal('saveProfileModal')">✕</button></div>
    <div class="modal-body">
      <div class="field"><div class="field-label">Profile Name</div><input type="text" id="profileNameInput" placeholder="e.g., NIN Tour, Festival Main"></div>
      <div class="field"><div class="field-label">Description</div><textarea id="profileDescInput" rows="2" placeholder="Notes..."></textarea></div>
    </div>
    <div class="modal-footer"><button class="btn" onclick="closeModal('saveProfileModal')">Cancel</button><button class="btn btn-primary" onclick="saveProfile()">Save</button></div>
  </div>
</div>
<div class="modal-overlay" id="manageProfilesModal">
  <div class="modal">
    <div class="modal-header"><h3>Manage Profiles</h3><button class="btn btn-icon" onclick="closeModal('manageProfilesModal')">✕</button></div>
    <div class="modal-body" id="profileList"></div>
    <div class="modal-footer"><button class="btn btn-sm" onclick="exportProfiles()">↗ Export</button><button class="btn btn-sm">↙ Import</button></div>
  </div>
</div>

<div class="toast-container" id="toasts"></div>

<script>
const CC=['#3b82f6','#22c55e','#f59e0b','#ef4444','#a855f7','#06b6d4','#ec4899'];
let nics=[], originalNames={};
async function api(p,m='GET',b=null){const o={method:m};if(b){o.headers={'Content-Type':'application/json'};o.body=JSON.stringify(b);}const r=await fetch(p,o);return r.json();}
async function fetchNics(){try{const d=await api('/api/nics');nics=Array.isArray(d)?d:[d];originalNames={};nics.forEach(n=>originalNames[n.ifIndex]=n.name);renderAll();document.getElementById('nicCount').textContent=nics.length+' Adapters';}catch(e){toast('error','Failed: '+e.message);}document.getElementById('loadingOverlay').style.opacity='0';document.getElementById('loadingOverlay').style.pointerEvents='none';}
let profiles=JSON.parse(localStorage.getItem('nicProfiles')||'{}');
let monitorTargets=[];
let monitorInterval=null;
let monitorRunning=false;

function sc(n){if(!n.enabled)return'disabled';if(n.status==='Up')return'up';if(n.status==='Disconnected')return'disconnected';return'down';}
function sl(n){if(!n.enabled)return'DISABLED';if(n.status==='Up')return n.linkSpeed||'Up';return n.status;}
function esc(s){return s==null?'':String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;');}

function switchTab(t){document.querySelectorAll('.tab-btn').forEach(b=>b.classList.toggle('active',b.dataset.tab===t));document.querySelectorAll('.page').forEach(p=>p.classList.toggle('active',p.id==='page-'+t));}

function renderSummary(){
  const up=nics.filter(n=>n.enabled&&n.status==='Up').length,disc=nics.filter(n=>n.enabled&&n.status!=='Up').length,off=nics.filter(n=>!n.enabled).length,dhcp=nics.filter(n=>n.dhcp).length;
  document.getElementById('summaryStrip').innerHTML=`
    <div class="s-card"><div class="s-num" style="color:var(--green)">${up}</div><div class="s-label">Connected</div></div>
    <div class="s-card"><div class="s-num" style="color:var(--amber)">${disc}</div><div class="s-label">Disconnected</div></div>
    <div class="s-card"><div class="s-num" style="color:var(--text-muted)">${off}</div><div class="s-label">Disabled</div></div>
    <div class="s-card"><div class="s-num" style="color:var(--cyan)">${dhcp}</div><div class="s-label">DHCP</div></div>
    <div class="s-card"><div class="s-num" style="color:var(--accent)">${nics.length-dhcp}</div><div class="s-label">Static</div></div>
    <div class="s-card"><div class="s-num">${nics.length}</div><div class="s-label">Total</div></div>`;
}

function renderQuick(){
  const b=document.getElementById('qBody');b.innerHTML='';
  nics.forEach((n,i)=>{const s=sc(n),color=CC[i%CC.length];
    b.innerHTML+=`<tr style="${!n.enabled?'opacity:.4':''}"><td style="padding:0"><div class="q-color" style="background:${color};height:54px"></div></td><td><div class="q-name"><span class="q-indicator ${s}"></span><input value="${esc(n.name)}" onchange="nics[${i}].name=this.value" spellcheck="false"></div><div class="q-hw">${esc(n.hw)} · ${n.mac}</div></td><td><span class="q-badge ${s}">${esc(sl(n))}</span></td><td><button class="toggle${n.dhcp?' active':''}" onclick="nics[${i}].dhcp=!nics[${i}].dhcp;renderAll()"></button></td><td><input value="${esc(n.ip)}" placeholder="—" onchange="nics[${i}].ip=this.value" ${n.dhcp?'disabled':''}></td><td><input value="${esc(n.subnet)}" placeholder="—" onchange="nics[${i}].subnet=this.value" ${n.dhcp?'disabled':''}></td><td><input value="${esc(n.gateway)}" placeholder="—" onchange="nics[${i}].gateway=this.value" ${n.dhcp?'disabled':''}></td><td><input value="${esc(n.dns1)}" placeholder="—" onchange="nics[${i}].dns1=this.value" ${n.dhcp?'disabled':''}></td><td><input value="${esc(n.dns2)}" placeholder="—" onchange="nics[${i}].dns2=this.value" ${n.dhcp?'disabled':''}></td><td><button class="toggle${n.enabled?' active':''}" onclick="nics[${i}].enabled=!nics[${i}].enabled;renderAll()"></button></td><td><button class="btn btn-sm btn-primary" onclick="applySingle(${i})">Apply</button></td></tr>`;
  });
}

function renderAdvanced(){
  const g=document.getElementById('advGrid');g.innerHTML='';
  nics.forEach((n,i)=>{const s=sc(n),color=CC[i%CC.length];const d=document.createElement('div');d.className='adv-card'+(!n.enabled?' off':'');d.style.setProperty('--nic-color',color);d.style.animationDelay=(i*.06)+'s';
    d.innerHTML=`<div class="adv-header"><div class="adv-dot ${s}"></div><div style="flex:1;min-width:0"><div class="adv-title">${esc(n.name)}</div><div class="adv-sub">${esc(n.hw)} · ${n.mac} · idx:${n.ifIndex}</div></div><span class="q-badge ${s}">${esc(sl(n))}</span></div><div class="adv-body"><div class="section-label" style="border:none;margin:0">Performance</div><div class="adv-3"><div class="field"><div class="field-label">MTU</div><input value="${esc(n.mtu)}" onchange="nics[${i}].mtu=this.value"></div><div class="field"><div class="field-label">Metric</div><input value="${esc(n.metric)}" placeholder="Auto" onchange="nics[${i}].metric=this.value"></div><div class="field"><div class="field-label">VLAN ID</div><input value="${esc(n.vlan)}" placeholder="None" onchange="nics[${i}].vlan=this.value"></div></div><div class="adv-2"><div class="field"><div class="field-label">Speed / Duplex</div><select onchange="nics[${i}].speedDuplex=this.value">${['Auto Negotiation','10 Mbps Full Duplex','10 Mbps Half Duplex','100 Mbps Full Duplex','100 Mbps Half Duplex','1.0 Gbps Full Duplex','2.5 Gbps Full Duplex'].map(x=>`<option${n.speedDuplex===x?' selected':''}>${x}</option>`).join('')}</select></div><div class="field"><div class="field-label">DNS Suffix</div><input value="${esc(n.dnsSuffix)}" placeholder="corp.local" onchange="nics[${i}].dnsSuffix=this.value"></div></div><div class="section-label">Features</div><div class="toggle-row"><span class="toggle-label">Jumbo Frames</span><button class="toggle${n.jumbo?' active':''}" onclick="nics[${i}].jumbo=!nics[${i}].jumbo;this.classList.toggle('active')"></button></div><div class="toggle-row"><span class="toggle-label">Wake on LAN</span><button class="toggle${n.wol?' active':''}" onclick="nics[${i}].wol=!nics[${i}].wol;this.classList.toggle('active')"></button></div><div class="toggle-row"><span class="toggle-label">QoS</span><button class="toggle${n.qos?' active':''}" onclick="nics[${i}].qos=!nics[${i}].qos;this.classList.toggle('active')"></button></div><div class="toggle-row"><span class="toggle-label">RSS</span><button class="toggle${n.rss?' active':''}" onclick="nics[${i}].rss=!nics[${i}].rss;this.classList.toggle('active')"></button></div><div class="toggle-row"><span class="toggle-label">Gratuitous ARP</span><button class="toggle${n.arp?' active':''}" onclick="nics[${i}].arp=!nics[${i}].arp;this.classList.toggle('active')"></button></div><div class="section-label">WINS / NetBIOS</div><div class="field"><div class="field-label">NetBIOS</div><select onchange="nics[${i}].netbios=this.value">${['Default','Enabled','Disabled'].map(x=>`<option${n.netbios===x?' selected':''}>${x}</option>`).join('')}</select></div><div class="toggle-row"><span class="toggle-label">LMHOSTS</span><button class="toggle${n.lmhosts?' active':''}" onclick="nics[${i}].lmhosts=!nics[${i}].lmhosts;this.classList.toggle('active')"></button></div><div class="toggle-row"><span class="toggle-label">Register DNS</span><button class="toggle${n.registerDns?' active':''}" onclick="nics[${i}].registerDns=!nics[${i}].registerDns;this.classList.toggle('active')"></button></div><div class="section-label">IPv6</div><div class="toggle-row"><span class="toggle-label">Enable IPv6</span><button class="toggle${n.ipv6?' active':''}" onclick="nics[${i}].ipv6=!nics[${i}].ipv6;this.classList.toggle('active')"></button></div><div class="adv-2"><div class="field"><div class="field-label">IPv6 Addr</div><input value="${esc(n.ipv6addr)}" placeholder="Auto"></div><div class="field"><div class="field-label">Prefix</div><input value="${esc(n.ipv6prefix)}" placeholder="64"></div></div></div><div class="adv-footer"><span class="ft">${n.dhcp?'DHCP':'Static'} · ${esc(n.ip||'—')} / ${esc(n.subnet)}</span><button class="btn btn-sm btn-primary" onclick="applySingle(${i})">Apply</button></div>`;
    g.appendChild(d);
  });
}


function buildPayload(ix){return ix.map(i=>{const n=nics[i];return{...n,originalName:originalNames[n.ifIndex]||n.name};});}
async function applySingle(i){toast('info','Applying '+nics[i].name+'...');try{const r=await api('/api/apply','POST',buildPayload([i]));const a=Array.isArray(r)?r:[r];a.forEach(x=>toast(x.success?'success':'error',x.name+': '+x.message));setTimeout(fetchNics,1500);}catch(e){toast('error',e.message);}}
async function applyAll(){toast('info','Applying all...');try{const r=await api('/api/apply','POST',buildPayload(nics.map((_,i)=>i)));const a=Array.isArray(r)?r:[r];let ok=0;a.forEach(x=>{if(x.success)ok++;else toast('error',x.name+': '+x.message);});if(ok)toast('success',ok+' configured');setTimeout(fetchNics,2000);}catch(e){toast('error',e.message);}}
async function refreshAll(){await fetchNics();toast('success','Refreshed');}

function renderAll(){renderSummary();renderQuick();renderAdvanced();updateProfileSelect();document.getElementById('nicCount').textContent=nics.length+' Adapters';}

/* ═══════════════════════════════════════════
   DIAGNOSTICS - SIMULATED FOR PREVIEW
   In the real .ps1 version these hit /api/ endpoints
   ═══════════════════════════════════════════ */

// Simulate realistic latency
function rndMs(base,jitter){return Math.max(1,base+Math.round((Math.random()-0.5)*jitter*2));}

// PING
async function runPing(){const t=document.getElementById('pingInput').value.trim(),c=document.getElementById('pingCount').value;if(!t)return;const o=document.getElementById('pingOutput');o.textContent='Pinging '+t+'...';try{const r=await api('/api/ping','POST',{target:t,count:parseInt(c)});o.textContent=r.output||'No response';}catch(e){o.textContent='Error: '+e.message;}}

// TRACEROUTE
async function runTrace(){const t=document.getElementById('traceInput').value.trim();if(!t)return;const o=document.getElementById('traceOutput');o.textContent='Tracing '+t+'...';try{const r=await api('/api/traceroute','POST',{target:t});o.textContent=r.output||'No response';}catch(e){o.textContent='Error: '+e.message;}}

// DNS
async function runDns(){const t=document.getElementById('dnsInput').value.trim(),ty=document.getElementById('dnsType').value;if(!t)return;const o=document.getElementById('dnsOutput');o.textContent='Looking up '+t+'...';try{const r=await api('/api/dns','POST',{target:t,type:ty});o.textContent=r.output||'No response';}catch(e){o.textContent='Error: '+e.message;}}

// PORT
async function runPort(){const h=document.getElementById('portHost').value.trim(),p=document.getElementById('portNum').value.trim();if(!h||!p)return;const o=document.getElementById('portOutput');o.textContent='Scanning '+h+'...';try{const r=await api('/api/portscan','POST',{target:h,ports:p});if(r.results){const sv={21:'ftp',22:'ssh',80:'http',443:'https',445:'smb',3389:'rdp',5568:'sacn',6454:'artnet',4700:'pixera'};let t='PORT       STATE     SERVICE\n';r.results.forEach(x=>{t+=String(x.port).padEnd(10)+' '+x.state.padEnd(9)+' '+(sv[x.port]||'')+'\n';});o.textContent=t.trimEnd();}else o.textContent=r.output||'No response';}catch(e){o.textContent='Error: '+e.message;}}

// ARP
async function runArp(){const o=document.getElementById('arpOutput');o.textContent='Loading...';try{const r=await api('/api/arp');o.textContent=r.output||'No data';}catch(e){o.textContent='Error: '+e.message;}}

// QUICK COMMANDS
async function runCmd(cmd){const out=document.getElementById('cmdOutput'),arpOut=document.getElementById('arpOutput');const normalized=cmd==='ipconfig /all'?'ipconfig_all':cmd==='route print'?'route_print':cmd;if(out)out.textContent='Running '+cmd+'...';try{const r=await api('/api/cmd','POST',{cmd:normalized});const msg=r.output||'No response';if(cmd==='arp_flush'){if(arpOut)arpOut.textContent=msg;toast('success','ARP cache flushed');}if(out)out.textContent=msg;}catch(e){const err='Error: '+e.message;if(out)out.textContent=err;if(cmd==='arp_flush'&&arpOut)arpOut.textContent=err;}}

/* ═══ PING MONITOR ═══ */
function addMonitorTarget(){const addr=document.getElementById('monitorAddInput').value.trim();const label=document.getElementById('monitorAddLabel').value.trim();if(!addr)return;monitorTargets.push({addr,label:label||addr,history:[],lastMs:null,status:'pending',sent:0,recv:0});document.getElementById('monitorAddInput').value='';document.getElementById('monitorAddLabel').value='';renderPingGrid();}

function addPresets(){const presets=[{addr:'192.168.1.1',label:'Default Gateway'},{addr:'10.0.0.1',label:'Media GW'},{addr:'172.16.0.1',label:'Control GW'},{addr:'8.8.8.8',label:'Google DNS'},{addr:'1.1.1.1',label:'Cloudflare DNS'},{addr:'google.com',label:'Google'}];presets.forEach(p=>{if(!monitorTargets.find(t=>t.addr===p.addr)){monitorTargets.push({...p,history:[],lastMs:null,status:'pending',sent:0,recv:0});}});renderPingGrid();toast('info','Added common targets');}

function removeTarget(i){monitorTargets.splice(i,1);renderPingGrid();}
function clearMonitor(){monitorTargets=[];stopMonitor();renderPingGrid();}

function toggleMonitor(){
  if(monitorRunning)stopMonitor();else startMonitor();
}
function startMonitor(){
  if(!monitorTargets.length){toast('error','Add targets first');return;}
  monitorRunning=true;
  document.getElementById('monitorToggle').innerHTML='⏸ Stop';
  document.getElementById('monitorToggle').className='btn btn-sm btn-danger';
  document.getElementById('monitorStatus').textContent='Running';
  document.getElementById('monitorStatus').style.color='var(--green)';
  doPingRound();
  monitorInterval=setInterval(doPingRound,3000);
}
function stopMonitor(){
  monitorRunning=false;
  clearInterval(monitorInterval);
  document.getElementById('monitorToggle').innerHTML='▶ Start';
  document.getElementById('monitorToggle').className='btn btn-sm btn-success';
  document.getElementById('monitorStatus').textContent='Stopped';
  document.getElementById('monitorStatus').style.color='';
}

async function doPingRound(){const ps=monitorTargets.map(async t=>{t.sent++;try{const r=await api('/api/singleping','POST',{target:t.addr});if(r.success&&r.ms>=0){t.history.push(r.ms);t.lastMs=r.ms;t.recv++;t.status='ok';}else{t.history.push(-1);t.lastMs=null;t.status='fail';}}catch{t.history.push(-1);t.lastMs=null;t.status='fail';}if(t.history.length>30)t.history.shift();});await Promise.all(ps);renderPingGrid();}

function renderPingGrid(){
  const grid=document.getElementById('pingGrid');
  if(!monitorTargets.length){grid.innerHTML='<div style="color:var(--text-muted);font-size:12px;padding:12px">No targets added. Add IPs or hostnames above, or click "Common Presets" for gateways + DNS.</div>';return;}
  grid.innerHTML='';
  monitorTargets.forEach((t,i)=>{
    const maxH=Math.max(1,...t.history.filter(h=>h>0));
    const el=document.createElement('div');
    el.className=`ping-target ${t.status}`;
    const avgMs=t.history.filter(h=>h>0);
    const avg=avgMs.length?Math.round(avgMs.reduce((a,b)=>a+b,0)/avgMs.length):0;
    const lossRate=t.sent?Math.round((1-t.recv/t.sent)*100):0;
    el.innerHTML=`
      <button class="ping-remove" onclick="removeTarget(${i})">✕</button>
      <div class="ping-target-name"><span class="ping-dot ${t.status}"></span>${esc(t.label)}</div>
      <div class="ping-target-addr">${esc(t.addr)}</div>
      <div class="ping-target-status ${t.status}">${t.lastMs!==null?t.lastMs+'<span style="font-size:11px;font-weight:400"> ms</span>':t.status==='pending'?'—':'TIMEOUT'}</div>
      <div class="ping-target-bar">${t.history.map(h=>{
        if(h<0)return'<div class="ping-bar fail" style="height:16px"></div>';
        const pct=Math.max(8,Math.round((h/Math.max(maxH,50))*100));
        const cls=h<30?'ok':h<80?'slow':'fail';
        return`<div class="ping-bar ${cls}" style="height:${pct}%"></div>`;
      }).join('')}</div>
      <div class="ping-stats"><span>avg: ${avg}ms</span><span>loss: ${lossRate}%</span><span>${t.sent} sent</span></div>`;
    grid.appendChild(el);
  });
}

/* ═══ PROFILES ═══ */
function updateProfileSelect(){const s=document.getElementById('profileSelect'),v=s.value;s.innerHTML='<option value="">— Select Profile —</option>';Object.keys(profiles).forEach(n=>{s.innerHTML+=`<option value="${esc(n)}">${esc(n)}</option>`;});s.value=v;}
function saveProfile(){const name=document.getElementById('profileNameInput').value.trim(),desc=document.getElementById('profileDescInput').value.trim();if(!name){toast('error','Enter a name');return;}profiles[name]={nics:JSON.parse(JSON.stringify(nics)),desc,date:new Date().toISOString()};localStorage.setItem('nicProfiles',JSON.stringify(profiles));updateProfileSelect();document.getElementById('profileSelect').value=name;closeModal('saveProfileModal');document.getElementById('profileNameInput').value='';document.getElementById('profileDescInput').value='';toast('success','Profile "'+name+'" saved');}
function loadProfile(name){if(!name||!profiles[name])return;nics=JSON.parse(JSON.stringify(profiles[name].nics));renderAll();toast('info','Loaded "'+name+'"');}
function executeProfile(){const name=document.getElementById('profileSelect').value;if(!name){toast('error','Select a profile');return;}loadProfile(name);toast('success','Executing "'+name+'"...');}
function showManageProfiles(){const list=document.getElementById('profileList'),keys=Object.keys(profiles);if(!keys.length){list.innerHTML='<p style="color:var(--text-muted);font-size:12px">No profiles yet.</p>';}else{list.innerHTML=keys.map(n=>{const p=profiles[n];return`<div class="profile-item"><div><div class="profile-item-name">${esc(n)}</div><div style="font-size:10px;color:var(--text-muted)">${esc(p.desc||'No description')} · ${new Date(p.date).toLocaleDateString()}</div></div><div class="profile-actions"><button class="btn btn-sm" onclick="loadProfile('${esc(n)}');closeModal('manageProfilesModal')">Load</button><button class="btn btn-sm btn-danger" onclick="deleteProfile('${esc(n)}')">Del</button></div></div>`;}).join('');}showModal('manageProfilesModal');}
function deleteProfile(n){delete profiles[n];localStorage.setItem('nicProfiles',JSON.stringify(profiles));showManageProfiles();updateProfileSelect();}
function exportProfiles(){const b=new Blob([JSON.stringify(profiles,null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='nic-profiles.json';a.click();}

function showModal(id){document.getElementById(id).classList.add('show');}
function closeModal(id){document.getElementById(id).classList.remove('show');}
document.querySelectorAll('.modal-overlay').forEach(m=>{m.addEventListener('click',e=>{if(e.target===m)closeModal(m.id);});});
function toast(type,msg){const c=document.getElementById('toasts'),t=document.createElement('div');t.className='toast '+type;t.innerHTML=`<span style="font-weight:600">${{success:'✓',error:'✕',info:'ℹ'}[type]||''}</span> ${msg}`;c.appendChild(t);setTimeout(()=>{t.style.opacity='0';t.style.transform='translateX(40px)';t.style.transition='all .3s';setTimeout(()=>t.remove(),300);},3500);}

fetchNics();
renderPingGrid();
</script>
</body>
</html>

'@

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request; $res = $ctx.Response; $path = $req.Url.AbsolutePath
        $res.Headers.Add("Access-Control-Allow-Origin","*")
        $res.Headers.Add("Access-Control-Allow-Methods","GET,POST,OPTIONS")
        $res.Headers.Add("Access-Control-Allow-Headers","Content-Type")
        if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode=200;$res.Close();continue }
        try { switch ($path) {
            "/" { Send-Resp $res $HTML "text/html; charset=utf-8"; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] UI served" -ForegroundColor DarkGray }
            "/api/nics" { Send-Resp $res (Get-NicDataJson); Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] GET nics" -ForegroundColor DarkGray }
            "/api/apply" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Applying..." -ForegroundColor Yellow; Send-Resp $res (Apply-NicConfig -JsonBody $b); Write-Host "  Done" -ForegroundColor Green }
            "/api/ping" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Ping" -ForegroundColor Cyan; Send-Resp $res (Run-Ping -J $b) }
            "/api/singleping" { $b=Read-Body $req; Send-Resp $res (Run-SinglePing -J $b) }
            "/api/traceroute" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Traceroute" -ForegroundColor Cyan; Send-Resp $res (Run-Traceroute -J $b) }
            "/api/dns" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] DNS" -ForegroundColor Cyan; Send-Resp $res (Run-DnsLookup -J $b) }
            "/api/portscan" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Port scan" -ForegroundColor Cyan; Send-Resp $res (Run-PortScan -J $b) }
            "/api/arp" { Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] ARP" -ForegroundColor Cyan; Send-Resp $res (Run-ArpTable) }
            "/api/cmd" { $b=Read-Body $req; Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Cmd" -ForegroundColor Yellow; Send-Resp $res (Run-Command -J $b) }
            default { $res.StatusCode=404; Send-Resp $res '{"error":"Not found"}' }
        } } catch { Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red; $res.StatusCode=500; Send-Resp $res "{`"error`":`"$($_.Exception.Message)`"}" }
        $res.Close()
    }
} catch {} finally { $listener.Stop();$listener.Close(); Write-Host "`nStopped." -ForegroundColor Yellow }
