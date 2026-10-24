param(
  [string]$Root = '',
  [int]$Port = 8765,
  [string]$UpstreamBase = 'https://open.bigmodel.cn/api/paas/v4'
)
if (-not $Root) { $Root = Join-Path $PSScriptRoot 'app' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Output "Serving $Root at http://127.0.0.1:$Port/"
Write-Output "API proxy: POST /__api/chat/completions -> $UpstreamBase/chat/completions (or ?up=<https-endpoint>)"
$rootPath = (Resolve-Path $Root).Path
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(90)
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $rel = $ctx.Request.Url.AbsolutePath
      if ($rel -eq '/__api/chat/completions') {
        $target = $UpstreamBase + '/chat/completions'
        $up = $ctx.Request.QueryString['up']
        if ($up -and $up -match '^https://') { $target = $up }
        $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $target)
        $req.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
        $auth = $ctx.Request.Headers['Authorization']
        if ($auth) { $req.Headers.TryAddWithoutValidation('Authorization', $auth) | Out-Null }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $ctx.Response.StatusCode = [int]$resp.StatusCode
        $ctx.Response.ContentType = 'application/json; charset=utf-8'
        $bytes = [Text.Encoding]::UTF8.GetBytes($respBody)
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        if ($rel -eq '/') { $rel = '/index.html' }
        $rel = $rel.TrimStart('/') -replace '/', '\'
        $file = Join-Path $Root $rel
      if ((Test-Path $file -PathType Leaf) -and ((Resolve-Path $file).Path.StartsWith($rootPath))) {
        $bytes = [IO.File]::ReadAllBytes($file)
        if ($file -like '*.html') { $ctx.Response.ContentType = 'text/html; charset=utf-8' }
        elseif ($file -like '*.js') { $ctx.Response.ContentType = 'application/javascript; charset=utf-8' }
        elseif ($file -like '*.css') { $ctx.Response.ContentType = 'text/css; charset=utf-8' }
        else { $ctx.Response.ContentType = 'application/octet-stream' }
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.Headers['Cache-Control'] = 'no-store'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
          $ctx.Response.StatusCode = 404
          $msg = [Text.Encoding]::UTF8.GetBytes('404')
          $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
        }
      }
    } catch { }
    finally { $ctx.Response.Close() }
  }
} finally { $listener.Stop() }
