@echo off
REM A stand-in for a supplier's in-house installer, kept IN THE REPOSITORY on purpose.
REM
REM Milestone 3 of docs/windows-management.md needs one measurable thing: install an in-house
REM EXE twice and see `changed: false` on the second pass. The first attempt at that proof used
REM a file in /tmp and an ad-hoc HTTP server, and both were gone when the claim was next checked
REM — so the milestone could neither be believed nor repeated. A fixture that lives beside its
REM recipe can be re-run by anyone, which is the whole point of a proof.
REM
REM It does exactly what the recipe's detection rule looks for and nothing else: writes the
REM version this package claims to be. No files, no services, nothing to clean up beyond one key.
REM /S is accepted and ignored, because a silent switch a real installer needs must be exercised
REM by the recipe rather than assumed to work.
reg add "HKLM\SOFTWARE\Acme\Widget" /v Version /t REG_SZ /d 4.2.1 /f >nul
if errorlevel 1 exit /b 1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AcmeWidget" /v DisplayName /t REG_SZ /d "Acme Widget" /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AcmeWidget" /v DisplayVersion /t REG_SZ /d 4.2.1 /f >nul
REM NO INNER QUOTES in the UninstallString. The first version wrote
REM     reg delete "HKLM\SOFTWARE\Acme\Widget" /f
REM and `package state=absent` found it, ran it, and got: FEHLER: Ungueltige Syntax. The string goes
REM through one more round of parsing when the module executes it, and the escaped quotes did not
REM survive it. The path has no spaces, so the quotes bought nothing and cost the uninstall.
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AcmeWidget" /v UninstallString /t REG_SZ /d "reg delete HKLM\SOFTWARE\Acme\Widget /f" /f >nul
exit /b 0
