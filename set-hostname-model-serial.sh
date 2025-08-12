#!/usr/bin/env bash
set -euo pipefail

# Set system hostname to "[model-name - serial-number]" (sanitized)
# Requires root. Will sudo-elevate itself if needed.

ensure_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

read_first_available_file() {
  # Args: file1 file2 ...
  local file_path
  for file_path in "$@"; do
    if [[ -r "$file_path" ]]; then
      # Some device-tree files are NUL-terminated; strip NUL and trailing newlines
      tr -d '\0' < "$file_path" | tr -d '\n'
      return 0
    fi
  done
  return 1
}

get_model_name() {
  local value=""
  value=$(read_first_available_file \
    /sys/devices/virtual/dmi/id/product_name \
    /sys/class/dmi/id/product_name \
    /proc/device-tree/model 2>/dev/null || true)

  if [[ -z "$value" ]] && command -v dmidecode >/dev/null 2>&1; then
    value=$(dmidecode -s system-product-name 2>/dev/null || true)
  fi

  if [[ -z "$value" ]]; then
    value="unknown-model"
  fi

  printf '%s' "$value"
}

get_serial_number() {
  local value=""
  value=$(read_first_available_file \
    /sys/devices/virtual/dmi/id/product_serial \
    /sys/class/dmi/id/product_serial \
    /proc/device-tree/serial-number 2>/dev/null || true)

  if [[ -z "$value" ]] && command -v dmidecode >/dev/null 2>&1; then
    value=$(dmidecode -s system-serial-number 2>/dev/null || true)
  fi

  if [[ -z "$value" ]] && [[ -r /proc/cpuinfo ]]; then
    value=$(awk -F ': *' '/^Serial/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  fi

  if [[ -z "$value" ]] && [[ -r /etc/machine-id ]]; then
    value=$(cut -c1-12 /etc/machine-id 2>/dev/null || true)
  fi

  if [[ -z "$value" ]]; then
    value="unknown-serial"
  fi

  printf '%s' "$value"
}

sanitize_label() {
  # Convert to a single RFC 1123-compatible hostname label
  # - lowercase
  # - replace spaces, slashes, underscores, dots with hyphens
  # - remove any char not [a-z0-9-]
  # - collapse multiple hyphens
  # - trim leading/trailing hyphens
  # - max 63 chars
  local s="$1"
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
  s=$(printf '%s' "$s" | sed -E 's/[\s_\/.]+/-/g')
  s=$(printf '%s' "$s" | sed -E 's/[^a-z0-9-]//g')
  s=$(printf '%s' "$s" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
  s=${s:0:63}
  if [[ -z "$s" ]]; then
    if [[ -r /etc/machine-id ]]; then
      s="host-$(cut -c1-8 /etc/machine-id)"
    else
      s="host-$(head -c 8 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
    fi
  fi
  printf '%s' "$s"
}

# Normalize pretty components: trim and collapse whitespace, preserve case and punctuation
normalize_pretty_component() {
  local s="$1"
  s=$(printf '%s' "$s" | tr -d '\0')
  s=$(printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
  printf '%s' "$s"
}

compose_hostname() {
  local model_raw serial_raw model serial combined max_len
  model_raw=$(get_model_name)
  serial_raw=$(get_serial_number)

  model=$(sanitize_label "$model_raw")
  serial=$(sanitize_label "$serial_raw")

  combined="${model}-${serial}"
  max_len=63

  if (( ${#combined} > max_len )); then
    if [[ -n "$serial" ]]; then
      local allow_for_model=$(( max_len - 1 - ${#serial} ))
      if (( allow_for_model < 1 )); then
        # Fall back to serial only, truncated
        combined=${serial:0:$max_len}
      else
        combined="${model:0:$allow_for_model}-${serial}"
      fi
    else
      combined=${model:0:$max_len}
    fi
  fi

  printf '%s' "$combined"
}

# Build a pretty computer name like "Model Name - Serial Number" (allows spaces and case)
compose_pretty_hostname() {
  local model_raw serial_raw model_pretty serial_pretty
  model_raw=$(get_model_name)
  serial_raw=$(get_serial_number)
  model_pretty=$(normalize_pretty_component "$model_raw")
  serial_pretty=$(normalize_pretty_component "$serial_raw")
  printf '%s - %s' "$model_pretty" "$serial_pretty"
}

# Write PRETTY_HOSTNAME to /etc/machine-info (systemd-compatible config)
set_pretty_machine_info() {
  local pretty="$1"
  local escaped
  escaped=$(printf '%s' "$pretty" | sed 's/"/\\"/g')
  if [[ -f /etc/machine-info ]]; then
    if grep -Eq '^PRETTY_HOSTNAME=' /etc/machine-info 2>/dev/null; then
      sed -i -E "s|^PRETTY_HOSTNAME=.*$|PRETTY_HOSTNAME=\"${escaped}\"|" /etc/machine-info
    else
      printf 'PRETTY_HOSTNAME="%s"\n' "$escaped" >> /etc/machine-info
    fi
  else
    printf 'PRETTY_HOSTNAME="%s"\n' "$escaped" > /etc/machine-info
  fi
}

apply_hostname() {
  local new_hostname="$1"
  local new_pretty="$2"
  local current_short
  current_short=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")

  if command -v hostnamectl >/dev/null 2>&1; then
    # Set static and pretty hostnames
    hostnamectl set-hostname "$new_hostname" --static
    hostnamectl set-hostname "$new_pretty" --pretty || true
  else
    printf '%s\n' "$new_hostname" > /etc/hostname
    hostname "$new_hostname" 2>/dev/null || true

    # Update /etc/hosts: adjust 127.0.1.1 mapping if present; otherwise append a line
    if grep -Eq '^[#[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
      sed -i -E "s|^[#[:space:]]*127\\.0\\.1\\.1[[:space:]].*|127.0.1.1\t${new_hostname}|" /etc/hosts
    else
      # If there is a 127.0.1.1 line commented out, replace it; else append new mapping
      if grep -Eq '^[#[:space:]]*#?[[:space:]]*127\.0\.1\.1' /etc/hosts 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*#?[[:space:]]*127\\.0\\.1\\.1.*|127.0.1.1\t${new_hostname}|" /etc/hosts
      else
        printf '\n127.0.1.1\t%s\n' "$new_hostname" >> /etc/hosts
      fi
    fi

    # Best-effort: replace occurrences of the old short hostname on 127.0.0.1 or 127.0.1.1 lines
    if [[ -n "$current_short" ]]; then
      local escaped_current_short
      escaped_current_short=$(printf '%s' "$current_short" | sed -e 's/[.[*^$(){}+?|\\]/\\&/g')
      sed -i -E "/^(127\\.0\\.0\\.1|127\\.0\\.1\\.1)[[:space:]]/ s/(^|[[:space:]])${escaped_current_short}([[:space:]]|$)/\\1${new_hostname}\\2/g" /etc/hosts || true
    fi

    # Best-effort pretty name storage for non-systemd systems
    set_pretty_machine_info "$new_pretty" || true
  fi
}

main() {
  ensure_root "$@"
  local target pretty_target
  target=$(compose_hostname)
  pretty_target=$(compose_pretty_hostname)

  echo "Current hostname: $(hostname)"
  echo "New hostname    : ${target}"
  echo "Pretty name     : ${pretty_target}"

  apply_hostname "$target" "$pretty_target"

  echo "Hostname successfully set to: ${target}"
}

main "$@"