## Cosa cambia / What changes

<!-- Un obiettivo per PR. Collega la issue: `Closes #…`. / One goal per PR. Link the issue: `Closes #…`. -->

## Come l'hai provato / How you tested it

<!-- Il dialogo reale con la TV non si testa offline: indica Control4 OS, Composer Pro, modello di TV e porta (8001/8002). -->
<!-- The real dialogue with the TV cannot be tested offline: state the Control4 OS, Composer Pro, TV model and port (8001/8002). -->

- Control4 OS / Composer Pro:
- TV (modello e anno / model and year):
- Porta / Port:

## Checklist

- [ ] `./tools/run_tests.ps1` è verde. / `./tools/run_tests.ps1` is green.
- [ ] I moduli puri (`lib/util`, `lib/net`, `lib/ws_frame`, `tv/protocol`) restano Lua 5.1 senza riferimenti a `C4`. / Pure modules stay Lua 5.1 with no `C4` reference.
- [ ] Nessun token, IP o dato personale nei log, nei test o nella documentazione. / No token, IP or personal data in logs, tests or documentation.
- [ ] Documentazione aggiornata (`README.md`, `src/www/documentation.rtf`, `docs/ARCHITECTURE.md` se cambia il flusso) e `CHANGELOG.md` (`[Unreleased]`). / Documentation updated and `CHANGELOG.md` (`[Unreleased]`).
- [ ] Nessun `.c4z` committato. / No `.c4z` committed.
- [ ] Il contributo non contiene codice di altri prodotti (in particolare `drivers-common-public` di Control4) né driver cifrati decifrati (regole clean-room). / The contribution contains no code from other products (in particular Control4's `drivers-common-public`) and no decrypted drivers (clean-room rules).
- [ ] Accetto che il mio lavoro sia rilasciato con licenza MIT. / I agree my work is released under the MIT licence.
