#!/usr/bin/env bash

# Root-Prüfung
if [ "$EUID" -ne 0 ]; then
	echo "Bitte als root ausführen!"
	exit 1
fi

set -e

# Option: --yes / -y zum Überspringen der Bestätigung
AUTO_YES=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		-y|--yes)
			AUTO_YES=1; shift ;;
		-h|--help)
			cat <<'USAGE'
Usage: update_debian.sh [-y|--yes]
	-y, --yes    Automatisch bestätigen (nicht empfohlen ohne Backup)
	-h, --help   Diese Hilfe
USAGE
			exit 0 ;;
		*) break ;;
	esac
done

# Confirm helper: default no.
confirm() {
	local msg="$1"
	if [ "$AUTO_YES" -eq 1 ]; then
		return 0
	fi
	# If not running in a TTY, don't attempt to prompt
	if [ ! -t 0 ]; then
		echo "[ERROR] Interaktive Bestätigung erforderlich, aber keine TTY. Führe das Script mit -y aus, wenn du sicher bist."
		return 2
	fi
	while true; do
		read -r -p "$msg [y/N]: " ans
		case "$ans" in
			[Yy]*) return 0 ;;
			[Nn]*|"") return 1 ;;
			*) echo "Bitte 'y' oder 'n' eingeben." ;;
		esac
	done
}

echo "[INFO] Update starten..."
apt update

echo "[INFO] Vorab-Upgrade: aktuelle Pakete für die laufende Release-Version installieren..."
apt upgrade -y
apt --purge autoremove -y

SKIP_REPO_CHECK=0
# Prüfe, ob Trixie bereits gesetzt ist
if grep -q 'trixie' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
	echo "[INFO] Repositories sind bereits auf Trixie gestellt. (Überspringe Erreichbarkeitsprüfung)"
	SKIP_REPO_CHECK=1
else
	# Variante 3: automatisches Backup + stille Umstellung
	echo "[INFO] Erstelle Backup der aktuellen Quellen (automatisch) und stelle Quellen still auf Trixie um."
	TS=$(date +%Y%m%d%H%M%S)
	BACKUP_DIR="/etc/apt/sources.list.d/backup-$TS"
	mkdir -p "$BACKUP_DIR"
	# Backup main sources.list into the backup dir (keep backups tidy)
	cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list.backup-$TS"
	echo "$BACKUP_DIR/sources.list.backup-$TS" > "$BACKUP_DIR/._backup_info"
	# Backup existing .list files; record their basenames (if none, note that)
	shopt -s nullglob
	orig_files=(/etc/apt/sources.list.d/*.list)
	if [ ${#orig_files[@]} -eq 0 ]; then
		printf '%s
' "# no .list files present" > "$BACKUP_DIR/orig_file_list.txt"
	else
		printf '%s
' "${orig_files[@]##*/}" > "$BACKUP_DIR/orig_file_list.txt"
		for f in "${orig_files[@]}"; do
			cp -a "$f" "$BACKUP_DIR/"
		done
	fi
	shopt -u nullglob

	# Hinweis: keine interaktive Nachfrage vor der Umstellung (Variante 3)
	sed -i 's/bookworm/trixie/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
	SKIP_REPO_CHECK=0
	echo "[INFO] Quellen umgestellt (Backup: $BACKUP_DIR)."
fi


# Suche alle 'deb' Zeilen, die 'trixie' enthalten
find_trixie_debs() {
	grep -hE '^\s*deb' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -i 'trixie' || true
}

# Parse a 'deb' line and print URL and suite separated by a space
parse_deb_line() {
	local line="$1"
	read -r -a tokens <<<"$line"
	local uri=""
	local suite=""
	for i in "${!tokens[@]}"; do
		tok=${tokens[$i]}
		if [[ $tok =~ ^(http|https|ftp):// ]] || [[ $tok =~ ^file: ]]; then
			uri=$tok
			# next token (if present) is the suite/distribution
			next_index=$((i+1))
			if [ $next_index -lt ${#tokens[@]} ]; then
				suite=${tokens[$next_index]}
			fi
			break
		fi
	done
	# fallback suite to 'trixie' if it contains 'trixie' somewhere or unknown
	if [ -z "$suite" ]; then
		if echo "$line" | grep -qi 'trixie-security'; then
			suite='trixie-security'
		else
			suite='trixie'
		fi
	fi
	printf '%s %s' "$uri" "$suite"
}

# Prüfe, ob <$url>/dists/<suite>/Release existiert (oder lokales file:)
check_trixie_repo() {
	local url="$1"
	local suite="$2"
	[ -n "$suite" ] || suite='trixie'
	local check_url
	if [[ $url == file:* ]]; then
		local path=${url#file:}
		path=${path%/}
		if [ -e "$path/dists/$suite/Release" ]; then
			return 0
		else
			return 1
		fi
	else
		check_url="${url%/}/dists/$suite/Release"
		if command -v curl >/dev/null 2>&1; then
			if curl -fsS --max-time 8 -I "$check_url" >/dev/null 2>&1; then
				return 0
			else
				return 1
			fi
		elif command -v wget >/dev/null 2>&1; then
			if wget --spider -q --timeout=8 "$check_url" >/dev/null 2>&1; then
				return 0
			else
				return 1
			fi
		else
			return 2
		fi
	fi
}

if [ "$SKIP_REPO_CHECK" -eq 1 ]; then
	echo "[INFO] Erreichbarkeitsprüfung übersprungen (Quellen bereits Trixie)."
else
	echo "[INFO] Überprüfe, ob mindestens eine Trixie-Quelle tatsächlich existiert..."
	mapfile -t trixie_lines < <(find_trixie_debs)

	if [ ${#trixie_lines[@]} -eq 0 ]; then
		echo "[WARN] Keine 'trixie' Quellen in den Apt-Listen gefunden. (Sollte vorher von sed gesetzt worden sein)"
	else
		reachable=0
		unverifiable=0
		failures=()

		# check each found line but keep output minimal: only failures are printed
		for l in "${trixie_lines[@]}"; do
			read -r url suite <<<"$(parse_deb_line "$l")"
			if [ -z "$url" ]; then
				failures+=("[WARN] Keine URL extrahiert: $l")
				continue
			fi
			if check_trixie_repo "$url" "$suite"; then
				reachable=$((reachable+1))
			else
				rc=$?
				if [ $rc -eq 2 ]; then
					unverifiable=$((unverifiable+1))
					failures+=("[UNVERIFIZIERBAR] $url (Suite: $suite) - Keine Prüfung möglich (curl/wget fehlt)")
				else
					failures+=("[NICHT ERREICHBAR] $url (Suite: $suite)")
				fi
			fi
		done

		# Ausgabe: nur Fehler oder kompakte Erfolgsmeldung
		if [ ${#failures[@]} -eq 0 ]; then
			echo "[OK] Alle geprüften Trixie-Quellen erreichbar (insgesamt: $reachable)."
		else
			echo "[ERROR] Einige Trixie-Quellen sind nicht erreichbar or unverifizierbar:"
			for msg in "${failures[@]}"; do
				echo "  $msg"
			done
		fi

		if [ $reachable -eq 0 ]; then
			echo "[ERROR] Keine erreichbare Trixie-Quelle gefunden. Abbruch."
			if [ $unverifiable -gt 0 ]; then
				echo "[HINT] Einige Quellen konnten nicht geprüft werden, weil 'curl' oder 'wget' fehlt. Installiere eines der Tools und wiederhole das Script."
			fi
			exit 3
		fi
	fi
fi

restore_backups_and_remove_new() {
	# Restore main sources.list if backup exists
	if [ -f "/etc/apt/sources.list.backup-$TS" ]; then
		cp -a "/etc/apt/sources.list.backup-$TS" /etc/apt/sources.list
		echo "[INFO] /etc/apt/sources.list wiederhergestellt"
	fi
	# Restore .list files from backup dir
	if [ -d "$BACKUP_DIR" ]; then
		# restore originals
		for bf in "$BACKUP_DIR"/*.list; do
			[ -e "$bf" ] || continue
			cp -a "$bf" "/etc/apt/sources.list.d/"
		done
		# remove any .list files that did not exist before
		shopt -s nullglob
		for cur in /etc/apt/sources.list.d/*.list; do
			name=${cur##*/}
			if ! grep -qxF "$name" "$BACKUP_DIR/orig_file_list.txt" 2>/dev/null; then
				rm -f "$cur"
				echo "[INFO] Entfernt neu erstellte Quelle: $name"
			fi
		done
		shopt -u nullglob
		echo "[INFO] Quellen aus $BACKUP_DIR wiederhergestellt."
	else
		echo "[WARN] Kein Backup-Verzeichnis gefunden: $BACKUP_DIR"
	fi
}

if confirm "Möchtest du jetzt das System auf Trixie upgraden (apt upgrade/full-upgrade)?"; then
	# Wenn /etc/os-release bereits Trixie meldet, überspringe das Upgrade
	if [ -r /etc/os-release ] && (grep -qi '^VERSION_CODENAME=.*trixie' /etc/os-release 2>/dev/null || grep -qi 'trixie' /etc/os-release 2>/dev/null); then
		echo "[INFO] /etc/os-release zeigt bereits Trixie. Upgrade übersprungen."
	else
		echo "[INFO] apt update und Upgrade nach Repo-Änderung..."
		apt update
		apt upgrade -y
		apt full-upgrade -y
		apt --purge autoremove -y
	fi
else
	echo "[INFO] Abgebrochen: Upgrade übersprungen. Stelle alte Quellen wieder her..."
	restore_backups_and_remove_new
	exit 0
fi

# Optional: Modernize sources falls vorhanden (robuste Erkennung)
if command -v modernize-sources >/dev/null 2>&1; then
	echo "[INFO] Führe 'modernize-sources' aus..."
	modernize-sources || echo "[WARN] modernize-sources schlug fehl"
elif command -v apt-modernize-sources >/dev/null 2>&1; then
	echo "[INFO] Führe 'apt-modernize-sources' aus..."
	apt-modernize-sources || echo "[WARN] apt-modernize-sources schlug fehl"
elif apt --help 2>/dev/null | grep -qi 'modernize'; then
	echo "[INFO] Führe 'apt modernize-sources' aus..."
	apt modernize-sources || echo "[WARN] 'apt modernize-sources' schlug fehl"
else
	echo '[INFO] Kein Modernize-Tool gefunden (modernize-sources/apt-modernize-sources). Die sources.list wurde nur ersetzt, aber nicht weiter modernisiert.'
fi
