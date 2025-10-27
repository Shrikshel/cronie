#!/usr/bin/env bash
#
# cronie - A friendly, interactive manager for systemd timers.

# --- Strict Mode & Error Handling ---
# Exit on error, undefined variable, or pipe failure.
set -Eeuo pipefail
# Trap errors and provide a helpful message.
trap 'echo -e "\n${COLOR_RED}Error: An unexpected error occurred on line $LINENO. Exiting.${COLOR_RESET}" >&2' ERR

# --- Global Variables & Constants ---
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME=$(basename "$0")

# --- Color Definitions for better UI ---
readonly COLOR_RESET='\e[0m'
readonly COLOR_RED='\e[0;31m'
readonly COLOR_GREEN='\e[0;32m'
readonly COLOR_YELLOW='\e[0;33m'
readonly COLOR_BLUE='\e[0;34m'
readonly COLOR_CYAN='\e[0;36m'
readonly COLOR_BOLD='\e[1m'

# --- Execution Context Variables (set by check_privileges) ---
SYSTEMCTL_ARGS=""
SYSTEMD_PATH=""
CRONIE_BASE_DIR=""
EXEC_MODE=""

# --- Logging and UI Helper Functions ---
_log_info() { echo -e "${COLOR_BLUE}INFO: $*${COLOR_RESET}" >&2; }
_log_success() { echo -e "${COLOR_GREEN}SUCCESS: $*${COLOR_RESET}" >&2; }
_log_error() { echo -e "${COLOR_RED}ERROR: $*${COLOR_RESET}" >&2; }
_log_warn() { echo -e "${COLOR_YELLOW}WARNING: $*${COLOR_RESET}" >&2; }
_log_prompt() { echo -e -n "${COLOR_YELLOW}$*${COLOR_RESET}" >&2; }

# --- Utility Functions ---

# Pauses execution until the user presses a key.
_press_any_key() {
    echo >&2
    read -n 1 -s -r -p "Press any key to continue..." >&2
    echo >&2
}

# Checks if a command exists in the system.
_command_exists() {
    command -v "$1" &>/dev/null
}

# Sanitizes a string to be a valid filename for systemd units.
_sanitize_name() {
    local name="$1"
    # Remove special characters, replace spaces/underscores with hyphens, and convert to lowercase.
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[ _]/-/g' -e 's/[^a-z0-9-]//g'
}

# Generates a short, random, and unique name for a timer.
_generate_random_name() {
    head /dev/urandom | tr -dc 'a-z0-9' | head -c 4
}

# Presents a menu of existing cronie timers for the user to select.
# Returns the selected timer name, or an empty string if cancelled.
_select_timer() {
    local timer_dirs
    mapfile -t timer_dirs < <(find "$CRONIE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [[ ${#timer_dirs[@]} -eq 0 ]]; then
        _log_warn "No 'cronie' timers found."
        _press_any_key
        return
    fi

    echo "Please select a timer:" >&2
    local i=1
    local options=()
    for dir in "${timer_dirs[@]}"; do
        options+=("$(basename "$dir")")
        echo "$i. $(basename "$dir")" >&2
        ((i++))
    done
    options+=("Cancel")
    echo "$i. Cancel" >&2

    local choice
    while true; do
        _log_prompt "Enter your choice [1-$i]: "
        read -r choice
        if [[ "$choice" -ge 1 && "$choice" -le ${#options[@]} ]]; then
            if [[ "${options[$choice-1]}" == "Cancel" ]]; then
                echo ""
                return
            fi
            echo "${options[$choice-1]}"
            return
        else
            _log_error "Invalid selection."
        fi
    done
}

# --- Core Logic: Timer Creation ---

# Guided workflow to determine the timer's schedule.
# Returns a string "ON_CALENDAR_VALUE|HUMAN_READABLE_INTERVAL".
_get_timer_schedule() {
    echo "Select the timer interval:" >&2
    local options=(
        "Every N Minutes"
        "Every N Hours"
        "Daily (at a specific time)"
        "Weekly (on a specific day and time)"
        "Monthly (on a specific day and time)"
        "Yearly (on a specific date and time)"
        "Custom OnCalendar Value"
        "Cancel"
    )
    
    select opt in "${options[@]}"; do
        case "$opt" in
            "Every N Minutes")
                _log_prompt "Enter minutes (1-59): "
                read -r n
                if ! [[ "$n" =~ ^[1-9]$|^[1-5][0-9]$ ]]; then _log_error "Invalid input."; continue; fi
                echo "*:0/${n}:00|Every ${n} minutes"
                return
                ;;
            "Every N Hours")
                _log_prompt "Enter hours (1-23): "
                read -r n
                if ! [[ "$n" =~ ^[1-9]$|^1[0-9]$|^2[0-3]$ ]]; then _log_error "Invalid input."; continue; fi
                echo "0 */${n}:00:00|Every ${n} hours"
                return
                ;;
            "Daily (at a specific time)")
                _log_prompt "Enter time (HH:MM): "
                read -r time
                if ! [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then _log_error "Invalid time format."; continue; fi
                echo "*-*-* ${time}:00|Daily at ${time}"
                return
                ;;
            "Weekly (on a specific day and time)")
                _log_prompt "Enter day (Mon, Tue, Wed, Thu, Fri, Sat, Sun): "
                read -r day
                if ! [[ "$day" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]; then _log_error "Invalid day."; continue; fi
                _log_prompt "Enter time (HH:MM): "
                read -r time
                if ! [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then _log_error "Invalid time format."; continue; fi
                echo "${day} *-*-* ${time}:00|Weekly on ${day} at ${time}"
                return
                ;;
            "Monthly (on a specific day and time)")
                _log_prompt "Enter day of month (1-31): "
                read -r day
                if ! [[ "$day" =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]]; then _log_error "Invalid day."; continue; fi
                _log_prompt "Enter time (HH:MM): "
                read -r time
                if ! [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then _log_error "Invalid time format."; continue; fi
                echo "*-*-${day} ${time}:00|Monthly on day ${day} at ${time}"
                return
                ;;
            "Yearly (on a specific date and time)")
                _log_prompt "Enter date (MM-DD): "
                read -r date
                if ! [[ "$date" =~ ^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then _log_error "Invalid date format."; continue; fi
                _log_prompt "Enter time (HH:MM, optional): "
                read -r time
                if [[ -z "$time" ]]; then time="00:00"; fi
                if ! [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then _log_error "Invalid time format."; continue; fi
                echo "*-${date} ${time}:00|Yearly on ${date} at ${time}"
                return
                ;;
            "Custom OnCalendar Value")
                _log_prompt "Enter valid systemd OnCalendar value: "
                read -r custom_cal
                echo "${custom_cal}|Custom: ${custom_cal}"
                return
                ;;
            "Cancel")
                return 1
                ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# Generates the content for the executable script based on a template.
# Returns the script content as a string.
_get_script_template_content() {
    local timer_name="$1"
    echo "Select a script template:" >&2
    local options=(
        "Empty Script"
        "Simple rsync Backup"
        "Website Health Check"
        "Cancel"
    )
    select opt in "${options[@]}"; do
        case "$opt" in
            "Empty Script")
                cat << EOF
#!/bin/bash
#
# Executable for timer: ${timer_name}
#
# This script is executed by the ${timer_name}.service.
# Add your commands here.

echo "Job '${timer_name}' executed at \$(date)"

# Example:
# touch /tmp/cronie_test_\$(date +%s)

EOF
                return
                ;;
            "Simple rsync Backup")
                _log_prompt "Enter SOURCE directory (absolute path): "
                read -r source_dir
                _log_prompt "Enter DESTINATION directory (absolute path): "
                read -r dest_dir
                if [[ -z "$source_dir" || -z "$dest_dir" ]]; then _log_error "Source and Destination cannot be empty."; continue; fi
                cat << EOF
#!/bin/bash
#
# Executable for timer: ${timer_name}
# Performs an rsync backup.

SOURCE="${source_dir}"
DESTINATION="${dest_dir}"

echo "Starting rsync backup from \$SOURCE to \$DESTINATION..."
rsync -av --delete "\$SOURCE/" "\$DESTINATION/"
echo "Backup completed."
EOF
                return
                ;;
            "Website Health Check")
                _log_prompt "Enter URL to check (e.g., https://google.com): "
                read -r url
                if ! [[ "$url" =~ ^https?:// ]]; then _log_error "Invalid URL format."; continue; fi
                cat << EOF
#!/bin/bash
#
# Executable for timer: ${timer_name}
# Performs a website health check.

URL_TO_CHECK="${url}"

echo "Checking status of \$URL_TO_CHECK..."
STATUS_CODE=\$(curl -o /dev/null -s -w "%{http_code}" "\$URL_TO_CHECK")

if [[ "\$STATUS_CODE" -ge 200 && "\$STATUS_CODE" -lt 300 ]]; then
    echo "SUCCESS: Website is up. Status code: \$STATUS_CODE"
else
    echo "FAILURE: Website might be down. Status code: \$STATUS_CODE"
fi
EOF
                return
                ;;
            "Cancel")
                return 1
                ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# Creates the .service and .timer systemd unit files.
_create_unit_files() {
    local timer_name="$1"
    local description="$2"
    local on_calendar_value="$3"
    local timer_dir="${CRONIE_BASE_DIR}/${timer_name}"
    local script_path="${timer_dir}/${timer_name}_EXECUTABLE_SCRIPT.sh"

    # Use an absolute path for ExecStart to avoid issues with system-wide services
    local home_dir
    home_dir=$(eval echo ~$(whoami))
    if [[ "$EUID" -eq 0 ]]; then
        home_dir="/root"
    fi
    local absolute_script_path="${home_dir}/cronie/${timer_name}/${timer_name}_EXECUTABLE_SCRIPT.sh"
    local absolute_log_path_base="${home_dir}/cronie/${timer_name}/logs"

    # Create .service file
    cat << EOF > "${SYSTEMD_PATH}/${timer_name}.service"
[Unit]
Description=${description}

[Service]
Type=oneshot
ExecStart=/bin/bash -c '${absolute_script_path} &>> "${absolute_log_path_base}/$(date +%%Y-%%m-%%d).log"'
EOF

    # Create .timer file
    cat << EOF > "${SYSTEMD_PATH}/${timer_name}.timer"
[Unit]
Description=${description}

[Timer]
OnCalendar=${on_calendar_value}
Persistent=false
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    _log_info "Created ${timer_name}.service and ${timer_name}.timer in ${SYSTEMD_PATH}"
}

# Main function for the "Create a new timer" workflow.
create_timer() {
    echo -e "\n${COLOR_CYAN}--- Create a New Timer ---${COLOR_RESET}"
    
    # 1. Get Timer Name
    _log_prompt "Enter a short name for the timer (alphanumeric, hyphens ok) [leave blank for random]: "
    read -r name_input
    local timer_name
    if [[ -z "$name_input" ]]; then
        timer_name=$(_generate_random_name)
        _log_info "Generated random name: ${timer_name}"
    else
        timer_name=$(_sanitize_name "$name_input")
    fi
    if [[ -d "${CRONIE_BASE_DIR}/${timer_name}" ]]; then
        _log_error "A timer with the name '${timer_name}' already exists."
        _press_any_key
        return
    fi

    # 2. Get Description
    local description=""
    while [[ -z "$description" ]]; do
        _log_prompt "Enter a one-line description for the timer's purpose: "
        read -r description
    done

    # 3. Get Schedule
    local schedule_info
    schedule_info=$(_get_timer_schedule) || { _log_info "Timer creation cancelled."; return; }
    local on_calendar_value human_interval
    IFS='|' read -r on_calendar_value human_interval <<< "$schedule_info"

    # 4. Get Script Template
    local script_content
    script_content=$(_get_script_template_content "$timer_name") || { _log_info "Timer creation cancelled."; return; }

    # 5. Create directories and files
    _log_info "Creating timer directory and files for '${timer_name}'..."
    local timer_dir="${CRONIE_BASE_DIR}/${timer_name}"
    local script_path="${timer_dir}/${timer_name}_EXECUTABLE_SCRIPT.sh"
    local info_log_path="${timer_dir}/${timer_name}_INFORMATION_LOG.log"
    mkdir -p "${timer_dir}/logs"

    echo "$script_content" > "$script_path"
    chmod +x "$script_path"

    # Create metadata log file
    cat << EOF > "$info_log_path"
Name: ${timer_name}
Description: ${description}
Interval: ${human_interval}
OnCalendar Value: ${on_calendar_value}
Creation Timestamp: $(date)
EOF

    # 6. Create systemd unit files
    _create_unit_files "$timer_name" "$description" "$on_calendar_value"

    # 7. Finalize
    _log_info "Reloading systemd daemon..."
    systemctl ${SYSTEMCTL_ARGS} daemon-reload
    _log_info "Enabling and starting timer '${timer_name}.timer'..."
    systemctl ${SYSTEMCTL_ARGS} enable --now "${timer_name}.timer"

    _log_success "Timer '${timer_name}' created and activated successfully!"
    _log_info "You can edit the executable script at: ${script_path}"
    _press_any_key
}

# --- Core Logic: Timer Management ---

# Lists all timers managed by cronie with their status.
list_timers() {
    echo -e "\n${COLOR_CYAN}--- List All Timers ---${COLOR_RESET}"
    local timer_dirs
    mapfile -t timer_dirs < <(find "$CRONIE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [[ ${#timer_dirs[@]} -eq 0 ]]; then
        _log_info "No 'cronie' timers found."
        _press_any_key
        return
    fi

    printf "%-25s %-12s %-30s %-30s\n" "TIMER NAME" "STATUS" "INTERVAL" "NEXT RUN"
    printf '%.0s-' {1..100} && echo

    for dir in "${timer_dirs[@]}"; do
        local timer_name
        timer_name=$(basename "$dir")
        local info_log="${dir}/${timer_name}_INFORMATION_LOG.log"

        if [[ ! -f "$info_log" ]]; then
            printf "%-25s %-12s %-30s %-30s\n" "$timer_name" "INVALID" "Info log missing" "n/a"
            continue
        fi

        # Get Status
        local status="inactive"
        if systemctl ${SYSTEMCTL_ARGS} is-enabled --quiet "${timer_name}.timer" &>/dev/null; then
            if systemctl ${SYSTEMCTL_ARGS} is-active --quiet "${timer_name}.timer" &>/dev/null; then
                status="${COLOR_GREEN}active${COLOR_RESET}"
            else
                status="${COLOR_YELLOW}enabled${COLOR_RESET}"
            fi
        else
            status="${COLOR_RED}paused${COLOR_RESET}"
        fi

        # Get Interval from log file
        local interval
        interval=$(grep "^Interval:" "$info_log" | cut -d' ' -f2-)

        # Get Next Run time using a reliable method
        local next_run
        next_run=$(systemctl ${SYSTEMCTL_ARGS} show "${timer_name}.timer" -p NextElapsedUSecRealtime --value 2>/dev/null || echo "n/a")
        if [[ "$next_run" == "0" || "$next_run" == "n/a" ]]; then
            next_run="n/a"
        fi

        printf "%-25s %-12b %-30s %-30s\n" "$timer_name" "$status" "$interval" "$next_run"
    done
    _press_any_key
}

# Sub-menu for managing logs of a specific timer.
_manage_logs_menu() {
    local timer_name="$1"
    local log_dir="${CRONIE_BASE_DIR}/${timer_name}/logs"

    while true; do
        echo -e "\n--- Log Management for '${COLOR_YELLOW}${timer_name}${COLOR_RESET}' ---"
        echo "1. View Logs"
        echo "2. Prune Old Logs"
        echo "3. Back to Manage Menu"
        _log_prompt "Select an option [1-3]: "
        read -r choice

        case "$choice" in
            1)
                local logs
                mapfile -t logs < <(find "$log_dir" -name "*.log" -type f 2>/dev/null | sort -r)
                if [[ ${#logs[@]} -eq 0 ]]; then
                    _log_info "No log files found for this timer."
                    _press_any_key
                    continue
                fi
                echo "Select a log file to view:"
                select log_file in "${logs[@]}" "Cancel"; do
                    if [[ "$log_file" == "Cancel" ]]; then break; fi
                    if [[ -n "$log_file" ]]; then
                        less "$log_file"
                        break
                    else
                        _log_error "Invalid selection."
                    fi
                done
                ;;
            2)
                _log_prompt "Delete logs older than how many days? "
                read -r days
                if ! [[ "$days" =~ ^[0-9]+$ ]]; then
                    _log_error "Invalid number of days."
                    continue
                fi
                _log_info "Finding and deleting logs older than ${days} days..."
                find "$log_dir" -name "*.log" -type f -mtime "+${days}" -print -delete
                _log_success "Log pruning complete."
                _press_any_key
                ;;
            3) return ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# Sub-menu for editing properties of a specific timer.
_edit_timer_menu() {
    local timer_name="$1"
    local timer_dir="${CRONIE_BASE_DIR}/${timer_name}"
    local info_log="${timer_dir}/${timer_name}_INFORMATION_LOG.log"
    local service_file="${SYSTEMD_PATH}/${timer_name}.service"
    local timer_file="${SYSTEMD_PATH}/${timer_name}.timer"

    while true; do
        echo -e "\n--- Edit Timer '${COLOR_YELLOW}${timer_name}${COLOR_RESET}' ---"
        echo "1. Edit Description"
        echo "2. Edit Schedule"
        echo "3. Edit Executable Script"
        echo "4. Back to Manage Menu"
        _log_prompt "Select an option [1-4]: "
        read -r choice

        case "$choice" in
            1)
                _log_prompt "Enter new description: "
                read -r new_desc
                if [[ -z "$new_desc" ]]; then _log_error "Description cannot be empty."; continue; fi
                sed -i "s|^Description=.*|Description=${new_desc}|" "$service_file"
                sed -i "s|^Description=.*|Description=${new_desc}|" "$timer_file"
                sed -i "s|^Description:.*|Description: ${new_desc}|" "$info_log"
                systemctl ${SYSTEMCTL_ARGS} daemon-reload
                _log_success "Description updated."
                _press_any_key
                ;;
            2)
                local schedule_info
                schedule_info=$(_get_timer_schedule) || { _log_info "Schedule edit cancelled."; continue; }
                local on_calendar_value human_interval
                IFS='|' read -r on_calendar_value human_interval <<< "$schedule_info"
                
                # Regenerate the timer file to ensure its format is correct and includes precision settings.
                local current_desc
                current_desc=$(grep "^Description=" "$timer_file" | cut -d'=' -f2-)
                cat << EOF > "$timer_file"
[Unit]
Description=${current_desc}

[Timer]
OnCalendar=${on_calendar_value}
Persistent=false
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
                sed -i "s|^Interval:.*|Interval: ${human_interval}|" "$info_log"
                sed -i "s|^OnCalendar Value:.*|OnCalendar Value: ${on_calendar_value}|" "$info_log"
                systemctl ${SYSTEMCTL_ARGS} daemon-reload
                systemctl ${SYSTEMCTL_ARGS} restart "${timer_name}.timer"
                _log_success "Schedule updated and timer restarted."
                _press_any_key
                ;;
            3)
                local script_path="${timer_dir}/${timer_name}_EXECUTABLE_SCRIPT.sh"
                "${EDITOR:-nano}" "$script_path"
                _log_success "Script updated. The changes will apply on the next run."
                _press_any_key
                ;;
            4) return ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# Main function for the "Manage an existing timer" workflow.
manage_timer() {
    echo -e "\n${COLOR_CYAN}--- Manage an Existing Timer ---${COLOR_RESET}"
    local timer_name
    timer_name=$(_select_timer)
    if [[ -z "$timer_name" ]]; then
        return # No timer selected or no timers exist, return to menu
    fi

    while true; do
        echo -e "\n--- Managing Timer: ${COLOR_YELLOW}${timer_name}${COLOR_RESET} ---"
        echo "1. Show Information"
        echo "2. Edit Timer (Description, Schedule, Script)"
        echo "3. Pause Timer (disable)"
        echo "4. Resume Timer (enable)"
        echo "5. Trigger Manually (Run Now)"
        echo "6. Log Management (View/Prune)"
        echo "7. Return to Main Menu"
        _log_prompt "Select an option [1-7]: "
        read -r choice

        case "$choice" in
            1)
                echo -e "\n--- Information for ${timer_name} ---"
                cat "${CRONIE_BASE_DIR}/${timer_name}/${timer_name}_INFORMATION_LOG.log"
                _press_any_key
                ;;
            2) _edit_timer_menu "$timer_name" ;;
            3)
                _log_info "Pausing (disabling) timer..."
                systemctl ${SYSTEMCTL_ARGS} disable --now "${timer_name}.timer"
                _log_success "Timer paused."
                _press_any_key
                ;;
            4)
                _log_info "Resuming (enabling) timer..."
                systemctl ${SYSTEMCTL_ARGS} enable --now "${timer_name}.timer"
                _log_success "Timer resumed."
                _press_any_key
                ;;
            5)
                _log_info "Triggering service manually..."
                systemctl ${SYSTEMCTL_ARGS} start "${timer_name}.service"
                _log_success "Service '${timer_name}.service' started. Check logs for output."
                _press_any_key
                ;;
            6) _manage_logs_menu "$timer_name" ;;
            7) return ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# Deletes a timer and all its associated files.
delete_timer() {
    echo -e "\n${COLOR_RED}${COLOR_BOLD}--- Delete a Timer ---${COLOR_RESET}"
    local timer_name
    timer_name=$(_select_timer)
    if [[ -z "$timer_name" ]]; then
        return # No timer selected or no timers exist, return to menu
    fi

    _log_warn "You are about to permanently delete the timer '${timer_name}'."
    _log_warn "This will stop the timer, remove its systemd files, and delete its data directory."
    _log_prompt "Are you absolutely sure? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        _log_info "Deletion aborted."
        _press_any_key
        return
    fi

    _log_info "Stopping and disabling timer..."
    systemctl ${SYSTEMCTL_ARGS} disable --now "${timer_name}.timer" &>/dev/null || true

    _log_info "Removing systemd unit files..."
    rm -f "${SYSTEMD_PATH}/${timer_name}.service" "${SYSTEMD_PATH}/${timer_name}.timer"

    _log_info "Reloading systemd daemon..."
    systemctl ${SYSTEMCTL_ARGS} daemon-reload

    _log_info "Deleting timer data directory..."
    rm -rf "${CRONIE_BASE_DIR}/${timer_name}"

    _log_success "Timer '${timer_name}' has been completely deleted."
    _press_any_key
}

# --- Core Logic: Backup & Restore ---

# Re-creates systemd units and enables a timer from its data directory.
_install_timer_from_dir() {
    local timer_name="$1"
    local timer_dir="${CRONIE_BASE_DIR}/${timer_name}"
    local info_log="${timer_dir}/${timer_name}_INFORMATION_LOG.log"

    if [[ ! -f "$info_log" ]]; then
        _log_error "Cannot install '${timer_name}', information log is missing."
        return 1
    fi

    _log_info "Installing timer '${timer_name}' from its directory..."
    local description on_calendar_value
    description=$(grep "^Description:" "$info_log" | cut -d' ' -f2-)
    on_calendar_value=$(grep "^OnCalendar Value:" "$info_log" | cut -d' ' -f3-)

    _create_unit_files "$timer_name" "$description" "$on_calendar_value"

    systemctl ${SYSTEMCTL_ARGS} daemon-reload
    systemctl ${SYSTEMCTL_ARGS} enable --now "${timer_name}.timer"
    _log_success "Timer '${timer_name}' installed and enabled."
}

# Creates a compressed archive of all cronie timers.
backup_all_timers() {
    echo -e "\n--- Backup All Timers ---"
    if [[ -z $(ls -A "$CRONIE_BASE_DIR") ]]; then
        _log_warn "Cronie base directory is empty. Nothing to back up."
        _press_any_key
        return
    fi

    local default_filename="cronie_backup_$(date +%Y-%m-%d_%H%M%S).tar.gz"
    _log_prompt "Enter path and filename for backup [${default_filename}]: "
    read -r backup_path
    if [[ -z "$backup_path" ]]; then
        backup_path="$default_filename"
    fi

    _log_info "Creating backup archive at '${backup_path}'..."
    tar -czf "$backup_path" -C "$(dirname "$CRONIE_BASE_DIR")" "$(basename "$CRONIE_BASE_DIR")"
    _log_success "Backup completed successfully."
    _press_any_key
}

# Restores timers from a backup archive.
restore_from_backup() {
    echo -e "\n--- Restore Timers from Backup ---"
    _log_prompt "Enter the full path to the backup file (.tar.gz): "
    read -r backup_file

    if [[ ! -f "$backup_file" ]]; then
        _log_error "Backup file not found at '${backup_file}'."
        _press_any_key
        return
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    _log_info "Extracting backup to a temporary location..."
    if ! tar -xzf "$backup_file" -C "$temp_dir"; then
        _log_error "Failed to extract backup file. It may be corrupted or not a valid archive."
        _press_any_key
        return
    fi

    local extracted_base_dir="${temp_dir}/cronie"
    if [[ ! -d "$extracted_base_dir" ]]; then
        _log_error "Backup archive does not contain a 'cronie' directory."
        _press_any_key
        return
    fi

    local restored_timers
    mapfile -t restored_timers < <(find "$extracted_base_dir" -mindepth 1 -maxdepth 1 -type d)
    if [[ ${#restored_timers[@]} -eq 0 ]]; then
        _log_warn "No timers found in the backup archive."
        _press_any_key
        return
    fi

    _log_info "Found ${#restored_timers[@]} timers in the backup."
    for timer_path in "${restored_timers[@]}"; do
        local timer_name
        timer_name=$(basename "$timer_path")
        echo "---"
        _log_info "Processing timer: ${timer_name}"

        if [[ -d "${CRONIE_BASE_DIR}/${timer_name}" ]]; then
            _log_warn "Timer '${timer_name}' already exists."
            _log_prompt "Choose an action: [O]verwrite, [S]kip, [A]bort restore? "
            read -r action
            case "$action" in
                [oO])
                    _log_info "Overwriting '${timer_name}'. Deleting existing version first."
                    # Non-interactive delete
                    systemctl ${SYSTEMCTL_ARGS} disable --now "${timer_name}.timer" &>/dev/null || true
                    rm -f "${SYSTEMD_PATH}/${timer_name}.service" "${SYSTEMD_PATH}/${timer_name}.timer"
                    rm -rf "${CRONIE_BASE_DIR}/${timer_name}"
                    systemctl ${SYSTEMCTL_ARGS} daemon-reload
                    ;;
                [sS])
                    _log_info "Skipping '${timer_name}'."
                    continue
                    ;;
                *)
                    _log_error "Restore aborted by user."
                    return
                    ;;
            esac
        fi
        
        _log_info "Restoring '${timer_name}' files..."
        cp -r "$timer_path" "$CRONIE_BASE_DIR/"
        _install_timer_from_dir "$timer_name"
    done

    _log_success "Restore process completed."
    _press_any_key
}

# Menu for backup and restore options.
backup_restore_menu() {
    while true; do
        echo -e "\n${COLOR_CYAN}--- Backup / Restore ---${COLOR_RESET}"
        echo "1. Backup All Timers"
        echo "2. Restore Timers from Backup"
        echo "3. Return to Main Menu"
        _log_prompt "Select an option [1-3]: "
        read -r choice

        case "$choice" in
            1) backup_all_timers ;;
            2) restore_from_backup ;;
            3) return ;;
            *) _log_error "Invalid option." ;;
        esac
    done
}

# --- Main Application Logic ---

# Main menu loop.
main_menu() {
    while true; do
        clear
        echo -e "${COLOR_CYAN}--- Cronie: The Friendly Timer Manager (v${SCRIPT_VERSION}) ---${COLOR_RESET}"
        echo -e "Operating in: ${COLOR_YELLOW}${EXEC_MODE}${COLOR_RESET}"
        echo "----------------------------------------------------"
        echo "1. Create a new timer"
        echo "2. List all timers"
        echo "3. Manage an existing timer"
        echo "4. Delete a timer"
        echo "5. Backup / Restore"
        echo "6. Exit"
        echo "----------------------------------------------------"
        _log_prompt "Select an option [1-6]: "
        read -r choice

        case "$choice" in
            1) create_timer ;;
            2) list_timers ;;
            3) manage_timer ;;
            4) delete_timer ;;
            5) backup_restore_menu ;;
            6) echo "Exiting."; exit 0 ;;
            *) _log_error "Invalid option. Please try again."; _press_any_key ;;
        esac
    done
}

# Determines execution context (root or user) and sets global variables.
check_privileges_and_setup() {
    if [[ "${EUID}" -eq 0 ]]; then
        EXEC_MODE="System-wide (root)"
        SYSTEMCTL_ARGS=""
        SYSTEMD_PATH="/etc/systemd/system"
        # Ensure HOME is set correctly for root
        export HOME=${HOME:-/root}
        CRONIE_BASE_DIR="${HOME}/cronie"
    else
        EXEC_MODE="User-level ($(whoami))"
        SYSTEMCTL_ARGS="--user"
        # Check for required environment variables for user mode, essential for systemd communication.
        if [[ -z "${XDG_RUNTIME_DIR-}" ]]; then
            _log_error "XDG_RUNTIME_DIR is not set. Cannot connect to the systemd user instance."
            _log_info "This can happen if you are using 'su' or 'sudo' without the '-l' flag."
            _log_info "Try logging in directly as the user or using a method that preserves the user environment."
            exit 1
        fi
        SYSTEMD_PATH="${HOME}/.config/systemd/user"
        CRONIE_BASE_DIR="${HOME}/cronie"
    fi

    # Create base directories if they don't exist
    mkdir -p "$CRONIE_BASE_DIR"
    mkdir -p "$SYSTEMD_PATH"
}

# --- Script Entry Point ---
main() {
    # Check dependencies
    for cmd in systemctl rsync tar curl less; do
        if ! _command_exists "$cmd"; then
            _log_error "Required command '${cmd}' is not installed. Please install it and try again."
            exit 1
        fi
    done

    check_privileges_and_setup
    main_menu
}

# Run the main function
main
