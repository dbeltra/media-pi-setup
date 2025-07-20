# Justwatch import script
Import movies from a public list into Radarr

# Setup
## Create a virtualenv
python3 -m venv /home/david/media-pi-setup/.venv

## Install requirements
. /home/david/media-pi-setup/.venv/bin/activate && pip install -r requirements.txt

## Set up .venv variables
cp .env.example .env
vim .env

## Give execution permissions to the script
chmod +x /home/david/media-pi-setup/scripts/import_justwatch.py

## Add it to crontab to run every 12 hours
crontab -e

0 */12 * * * /home/david/media-pi-setup/.venv/bin/python /home/david/media-pi-setup/scripts/import_justwatch.py >> /home/david/media-server-config/scripts/import_justwatch.log 2>&1
