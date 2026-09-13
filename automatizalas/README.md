# Automatizálási példák

1. `generate_network.py`: Python 3 standard library, két IOS VLAN-konfiguráció generálása.
2. `apply_network.py`: opcionális SSH-alkalmazás valódi/emulált IOS-ra; előnézet az alapértelmezés. Függőség külön venv-ben: `python3 -m venv .venv`, `. .venv/bin/activate`, `python -m pip install netmiko`. A kipróbált csomagverziókat `python -m pip freeze > requirements-tested.txt` paranccsal dokumentáld. Ezt a környezetet itt nem telepítettük és nem kapcsolódtunk eszközhöz.
3. `clients.ini` és `install_clients.yml`: az Ubuntu szerverről a külön Linux kliensre telepít `tree` és `curl` csomagot, SSH-n és sudo-n keresztül, VM3 szerint.

SSH-alkalmazás előtt a hostkulcs ujjlenyomatát a készülék megbízható konzoljából vesd össze a kliensen megjelenővel, majd megbízható `known_hosts` bejegyzést használj. A szkript ismeretlen vagy eltérő kulcsnál megáll. Előnézet: `python apply_network.py`. Alkalmazás: `python apply_network.py --apply`. Nem végez automatikus rollbacket: részleges hiba esetén az első eszköz már módosulhatott. Konzolos hozzáférés és az előzetes konfigurációmentés szükséges. A mentés titkokat tartalmazhat; a beadásba csak kitakart változat kerüljön.

A programozott hálózatkonfiguráció és a kliens-szoftverterítés két külön követelmény. A Linux apt-playbook nem helyettesíti a router/switch konfigurációjának bemutatását.
