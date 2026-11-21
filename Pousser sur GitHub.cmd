@echo off
rem Envoie Service Minimum sur GitHub avec les identifiants Git de ce poste
cd /d "%~dp0"
where git >nul 2>nul
if errorlevel 1 (
  echo Git n est pas installe sur ce poste : https://git-scm.com/download/win
  pause
  exit /b 1
)
if exist .git goto suite
git init -q
git remote add origin https://github.com/JOSINGENET/Serviceminimum.git
git fetch -q origin main
if errorlevel 1 goto suite
rem Premier envoi depuis ce poste : reprend l historique deja publie sans toucher aux fichiers du dossier
git symbolic-ref HEAD refs/heads/main
git update-ref refs/heads/main refs/remotes/origin/main
git reset -q
:suite
git add -A
git diff --cached --quiet
if errorlevel 1 git commit -m "Mise a jour Service Minimum"
if errorlevel 1 (
  echo.
  echo Le commit a echoue. Si Git demande votre identite, lancez une fois :
  echo   git config --global user.name "Votre nom"
  echo   git config --global user.email "votre@adresse"
  pause
  exit /b 1
)
git branch -M main
git remote get-url origin >nul 2>nul
if errorlevel 1 git remote add origin https://github.com/JOSINGENET/Serviceminimum.git
git pull -q --rebase origin main
git push -u origin main
echo.
if errorlevel 1 (echo L envoi a echoue, voir le message ci-dessus.) else (echo Envoi termine.)
pause
