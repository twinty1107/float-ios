# 重做本地 git 仓库：清掉 CRLF 污染，锁定行尾后重新提交
# 用法：在 D:\float-ios 目录下执行  powershell -ExecutionPolicy Bypass -File .\setup-repo.ps1

$ErrorActionPreference = 'Stop'

Write-Host "=== 1/4 检查 git 身份 ===" -ForegroundColor Cyan
# git config 取不到值时会往 stderr 输出，这里静默处理
$curEmail = (git config user.email) 2>$null
$curName  = (git config user.name) 2>$null
if ([string]::IsNullOrWhiteSpace($curEmail)) {
    $curEmail = Read-Host "  git 邮箱（随便填，如 me@example.com）"
    git config user.email $curEmail
}
if ([string]::IsNullOrWhiteSpace($curName)) {
    $curName = Read-Host "  git 名字（随便填）"
    git config user.name $curName
}
$curEmail = (git config user.email) 2>$null
$curName  = (git config user.name) 2>$null
if ([string]::IsNullOrWhiteSpace($curEmail) -or [string]::IsNullOrWhiteSpace($curName)) {
    Write-Host "  错误：git 身份仍未配置，无法提交。" -ForegroundColor Red
    exit 1
}
Write-Host ("  user.email = " + $curEmail)
Write-Host ("  user.name  = " + $curName)

Write-Host "=== 2/4 重建本地仓库（清掉 CRLF 污染） ===" -ForegroundColor Cyan
if (Test-Path .git) { Remove-Item .git -Recurse -Force }
git init | Out-Null
git config core.autocrlf false
git config core.eol lf
Write-Host "  已重建，autocrlf=false"

Write-Host "=== 3/4 暂存并校验行尾 ===" -ForegroundColor Cyan
git add -A
$eol = git ls-files --eol
$bad = $eol | Select-String -Pattern 'crlf'
if ($bad) {
    Write-Host "  仍有 CRLF 的文件：" -ForegroundColor Yellow
    $bad | ForEach-Object { Write-Host ("    " + $_.Line) }
} else {
    Write-Host "  行尾正常：无 CRLF" -ForegroundColor Green
}
Write-Host "  关键文件行尾："
$eol | Select-String -Pattern 'build-ipa\.sh|verify\.sh|project\.pbxproj|build-ipa\.yml|float-unsigned\.ipa' |
    ForEach-Object { Write-Host ("    " + $_.Line) }

Write-Host "=== 4/4 提交 ===" -ForegroundColor Cyan
git commit -m "float iOS 封装工程: WKWebView 外壳 + Xcode 工程 + GitHub Actions 构建" | Out-Null
git log --oneline

Write-Host ""
Write-Host "完成。接下来：" -ForegroundColor Green
Write-Host "  1) 打开 https://github.com/new 建一个空的 Public 仓库（三个初始化选项都不要勾）"
Write-Host "  2) 复制仓库网址，然后依次执行："
Write-Host '       git remote add origin "粘贴网址"'
Write-Host '       git branch -M main'
Write-Host '       git push -u origin main'
