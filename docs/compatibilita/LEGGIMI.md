# Rapporti di compatibilità

Un file `.json` per ogni rapporto ricevuto (formato di `sweetspot-rapporto`),
con un nome come `2026-10-11-asus-n550jv-r26.json`. Dopo averne aggiunto uno:

    python3 tools/matrice-compatibilita.py

rigenera [`../compatibilita.md`](../compatibilita.md); la CI controlla che la
pagina sia aggiornata.
