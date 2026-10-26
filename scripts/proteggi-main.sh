#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - protegge il ramo main su GitHub (vedi docs/supply-chain.md).
#
#   ./scripts/proteggi-main.sh            mostra la protezione attuale
#   ./scripts/proteggi-main.sh --applica  la imposta (serve essere amministratori)
#
# Su main si entra solo con una pull request il cui controllo "esito" (job
# finale di build.yml: test, compilazione, triage delle CVE e prove Lyrion
# senza fallimenti ne' annullamenti) e' riuscito, anche per gli
# amministratori. Niente push forzati ne' cancellazioni. Il controllo e'
# legato all'app GitHub Actions (app_id 15368), cosi' uno stato impostato a
# mano con l'API non lo sostituisce. Non si chiede che il ramo sia allineato
# a main (strict): obbligherebbe a ricompilare per ore a ogni merge.
# Serve gh autenticato (gh auth login).
set -e
REPO=${REPO:-Markg981/sweetspot}
command -v gh > /dev/null || { echo "Serve gh: https://cli.github.com"; exit 1; }
if [ "${1:-}" != --applica ]; then
	gh api "repos/$REPO/branches/main/protection" || echo "main non e' protetto."
	exit 0
fi
gh api -X PUT "repos/$REPO/branches/main/protection" --input - <<'FINE'
{
  "required_status_checks": {
    "strict": false,
    "checks": [{"context": "esito", "app_id": 15368}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
FINE
echo "main protetto: serve il controllo \"esito\" riuscito."
