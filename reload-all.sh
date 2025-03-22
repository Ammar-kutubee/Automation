#!/bin/bash
set -e # Exit on error

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
PURPLE='\033[0;35m'
CYAN='\033[0;36m'

# Default values
ENV_NAME="Kutubee2-core-prod"
AWS_PROFILE="admin-kutubee-ammar"
SSH_KEY="$HOME/.ssh/LiveKububee.pem"

PARALLEL_MODE=false
DRY_RUN=false
ROLLING_RELOAD=false
MAX_RETRIES=2
RETRY_DELAY=5
COMMAND_TIMEOUT=120
LOG_FILE="$HOME/pm2_reload_$(date +%Y%m%d_%H%M%S).log"
CONFIG_FILE="$HOME/.pm2reload.conf"
HEALTH_CHECK_TIMEOUT=30
GUI_SELECT=false

# Add this function near the top, in the utility functions section
# Function to detect and use the best available terminal UI tool
detect_terminal_ui() {
  # Check for dialog (most feature-rich)
  if command -v dialog &>/dev/null; then
    TUI_TOOL="dialog"
    return 0
  # Check for whiptail (available on Debian/Ubuntu by default)
  elif command -v whiptail &>/dev/null; then
    TUI_TOOL="whiptail"
    return 0
  # Check for zenity (for X11/Wayland desktop environments)
  elif command -v zenity &>/dev/null && [ -n "$DISPLAY" ]; then
    TUI_TOOL="zenity"
    return 0
  fi

  # No TUI tool available
  TUI_TOOL="none"
  return 1
}

# Use TUI tool for interactive selection
use_tui_selection() {
  local temp_selection
  local dialog_exit

  case $TUI_TOOL in
  "dialog")
    log "INFO" "Using dialog for instance selection..."
    temp_selection=$(mktemp)

    # Build dialog checklist options
    options=()
    for i in "${!INSTANCE_ARRAY[@]}"; do
      options+=("$i" "${INSTANCE_ARRAY[$i]}" "off")
    done

    # Display checklist dialog
    dialog --title "Instance Selection" \
      --checklist "Select instances to reload (use SPACE to select, ENTER to confirm):" 20 70 10 \
      "${options[@]}" 2>"$temp_selection"

    dialog_exit=$?
    if [ $dialog_exit -eq 0 ]; then
      # Parse selected instances
      selected_indices=$(cat "$temp_selection")
      rm "$temp_selection"

      # Add selected instances to array
      SELECTED_INSTANCES=()
      for idx in $selected_indices; do
        SELECTED_INSTANCES+=("${INSTANCE_ARRAY[$idx]}")
      done
    else
      # Dialog was cancelled
      log "INFO" "Selection cancelled, defaulting to all instances"
      SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
    fi
    ;;

  "whiptail")
    log "INFO" "Using whiptail for instance selection..."
    temp_selection=$(mktemp)

    # Build whiptail checklist options
    options=()
    for i in "${!INSTANCE_ARRAY[@]}"; do
      options+=("$i" "${INSTANCE_ARRAY[$i]}" "OFF")
    done

    # Display checklist whiptail
    whiptail --title "Instance Selection" \
      --checklist "Select instances to reload (use SPACE to select, ENTER to confirm):" 20 70 10 \
      "${options[@]}" 2>"$temp_selection"

    dialog_exit=$?
    if [ $dialog_exit -eq 0 ]; then
      # Parse selected instances
      selected_indices=$(cat "$temp_selection")
      rm "$temp_selection"

      # Add selected instances to array
      SELECTED_INSTANCES=()
      for idx in $selected_indices; do
        # Whiptail outputs with quotes, remove them
        idx=$(echo $idx | tr -d '"')
        SELECTED_INSTANCES+=("${INSTANCE_ARRAY[$idx]}")
      done
    else
      # Dialog was cancelled
      log "INFO" "Selection cancelled, defaulting to all instances"
      SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
    fi
    ;;

  "zenity")
    log "INFO" "Using zenity for instance selection..."

    # Create a temporary file for the list
    temp_list=$(mktemp)

    # Build zenity list
    for i in "${!INSTANCE_ARRAY[@]}"; do
      echo "FALSE|$i|${INSTANCE_ARRAY[$i]}" >>"$temp_list"
    done

    # Display zenity list dialog
    selected_indices=$(zenity --list --title="Instance Selection" \
      --text="Select instances to reload:" \
      --checklist --column="Select" --column="ID" --column="Instance" \
      --separator=" " --height=400 --width=600 \
      $(cat "$temp_list"))

    dialog_exit=$?
    rm "$temp_list"

    if [ $dialog_exit -eq 0 ]; then
      # Add selected instances to array
      SELECTED_INSTANCES=()
      for idx in $selected_indices; do
        SELECTED_INSTANCES+=("${INSTANCE_ARRAY[$idx]}")
      done
    else
      # Dialog was cancelled
      log "INFO" "Selection cancelled, defaulting to all instances"
      SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
    fi
    ;;

  *)
    # No TUI available - return false to use text-based fallback
    return 1
    ;;
  esac

  # If nothing was selected but dialog completed successfully, default to all instances
  if [ ${#SELECTED_INSTANCES[@]} -eq 0 ] && [ $dialog_exit -eq 0 ]; then
    log "INFO" "No instances selected, defaulting to all instances"
    SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
  fi

  return 0
}

# Display help
show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -e, --env ENV_NAME         Environment name (default: $ENV_NAME)
  -p, --profile PROFILE      AWS profile (default: $AWS_PROFILE)
  -k, --key SSH_KEY          SSH key path (default: $SSH_KEY)
  -s, --sequential           Run in sequential mode (default)
  -a, --parallel             Run in parallel mode
  -r, --rolling              Use rolling reload (one at a time with health check)
  -d, --dry-run              Show what would happen without making changes
  -g, --gui-select           Use GUI dialogs for instance selection if available
  -c, --config FILE          Use config file (default: $CONFIG_FILE)
  -t, --timeout SECONDS      Command timeout in seconds (default: $COMMAND_TIMEOUT)
  -n, --no-prompt            Non-interactive mode (no prompts)
  -l, --log FILE             Log file (default: $LOG_FILE)
  -h, --help                 Show this help message

EOF
  exit 0
}

# Logging function
log() {
  local level=$1
  local message=$2
  local color=$NC

  case $level in
  "INFO") color=$BLUE ;;
  "SUCCESS") color=$GREEN ;;
  "WARNING") color=$YELLOW ;;
  "ERROR") color=$RED ;;
  esac

  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo -e "${color}[$timestamp] [$level] $message${NC}" | tee -a "$LOG_FILE"
}

# Progress spinner
spinner() {
  local pid=$1
  local message=$2
  local spin='-\|/'
  local i=0

  while kill -0 $pid 2>/dev/null; do
    i=$(((i + 1) % 4))
    printf "\r${YELLOW}[%c] %s...${NC}" "${spin:$i:1}" "$message"
    sleep 0.1
  done
  printf "\r                                                                \r"
}

# Cleanup function
cleanup() {
  log "INFO" "Cleaning up temporary files..."
  kill $(jobs -p) 2>/dev/null || true
  rm -f /tmp/pm2_reload_*.log
  log "INFO" "Logs saved to $LOG_FILE"
  exit 1
}

# Handle timeouts
timeout_handler() {
  local cmd=$1
  local timeout=$2
  local pid

  eval "$cmd" &
  pid=$!

  # Start spinner in background
  (spinner $pid "Running command with timeout ${timeout}s") &
  spinner_pid=$!

  # Wait for command with timeout
  local start_time=$(date +%s)
  while kill -0 $pid 2>/dev/null && [ $(($(date +%s) - start_time)) -lt $timeout ]; do
    sleep 0.5
  done

  # Check if it's still running after timeout
  if kill -0 $pid 2>/dev/null; then
    kill $pid
    kill $spinner_pid 2>/dev/null
    log "ERROR" "Command timed out after ${timeout}s"
    return 1
  else
    kill $spinner_pid 2>/dev/null
    wait $pid
    return $?
  fi
}

# Load config file if exists
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    log "INFO" "Loading configuration from $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

# Save current config to file
save_config() {
  log "INFO" "Saving configuration to $CONFIG_FILE"
  cat >"$CONFIG_FILE" <<EOF
# PM2 Reload Manager Configuration
ENV_NAME="$ENV_NAME"
AWS_PROFILE="$AWS_PROFILE"
SSH_KEY="$SSH_KEY"
PARALLEL_MODE=$PARALLEL_MODE
ROLLING_RELOAD=$ROLLING_RELOAD
MAX_RETRIES=$MAX_RETRIES
RETRY_DELAY=$RETRY_DELAY
COMMAND_TIMEOUT=$COMMAND_TIMEOUT
GUI_SELECT=$GUI_SELECT
EOF
}

# Parse command line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      show_help
      ;;
    -e | --env)
      ENV_NAME="$2"
      shift 2
      ;;
    -p | --profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    -k | --key)
      SSH_KEY="$2"
      shift 2
      ;;
    -s | --sequential)
      PARALLEL_MODE=false
      shift
      ;;
    -a | --parallel)
      PARALLEL_MODE=true
      shift
      ;;
    -r | --rolling)
      ROLLING_RELOAD=true
      PARALLEL_MODE=false
      shift
      ;;
    -d | --dry-run)
      DRY_RUN=true
      shift
      ;;
    -g | --gui-select)
      GUI_SELECT=true
      shift
      ;;
    -c | --config)
      CONFIG_FILE="$2"
      load_config
      shift 2
      ;;
    -t | --timeout)
      COMMAND_TIMEOUT="$2"
      shift 2
      ;;
    -n | --no-prompt)
      NO_PROMPT=true
      shift
      ;;
    -l | --log)
      LOG_FILE="$2"
      shift 2
      ;;
    *)
      log "ERROR" "Unknown option: $1"
      show_help
      ;;
    esac
  done
}

# Function to verify health of an instance after reload
check_health() {
  local instance=$1
  local START_TIME=$(date +%s)

  log "INFO" "Performing health check on instance $instance..."

  # Run health check command - modify this to use your actual health check
  local health_cmd="eb ssh --profile \"$AWS_PROFILE\" \"$ENV_NAME\" --instance \"$instance\" \
        --custom \"ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no\" \
        -c \"sudo su - webapp -c 'pm2 status | grep -q online'\""

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "[DRY RUN] Would run health check: $health_cmd"
    return 0
  fi

  # Try health check with exponential backoff
  local attempt=1
  local max_attempts=5
  local wait_time=5

  while [ $attempt -le $max_attempts ]; do
    log "INFO" "Health check attempt $attempt/$max_attempts..."

    if timeout_handler "$health_cmd" "$HEALTH_CHECK_TIMEOUT"; then
      local END_TIME=$(date +%s)
      local DURATION=$((END_TIME - START_TIME))
      log "SUCCESS" "Instance $instance is healthy (${DURATION}s)"
      return 0
    fi

    log "WARNING" "Health check failed, waiting ${wait_time}s before retry..."
    sleep $wait_time
    wait_time=$((wait_time * 2))
    ((attempt++))
  done

  log "ERROR" "Health check failed after $max_attempts attempts on instance $instance"
  return 1
}

# Function to reload PM2 on a single instance with retry mechanism
reload_instance() {
  local instance=$1
  local START_TIME=$(date +%s)

  log "INFO" "Reloading PM2 on instance $instance..."

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "[DRY RUN] Would reload PM2 on instance $instance"
    sleep 2 # Simulate work
    return 0
  fi

  local cmd="eb ssh --profile \"$AWS_PROFILE\" \"$ENV_NAME\" --instance \"$instance\" \
        --custom \"ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no\" \
        -c \"sudo su - webapp -c 'pm2 reload all'\""

  # Retry mechanism
  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    log "INFO" "Attempt $attempt/$MAX_RETRIES on instance $instance"

    if timeout_handler "$cmd" "$COMMAND_TIMEOUT" >"/tmp/pm2_reload_${instance}.log" 2>&1; then
      local END_TIME=$(date +%s)
      local DURATION=$((END_TIME - START_TIME))
      log "SUCCESS" "Successfully reloaded PM2 on $instance (${DURATION}s)"

      # Perform health check if in rolling mode
      if [ "$ROLLING_RELOAD" = true ]; then
        if ! check_health "$instance"; then
          log "ERROR" "Health check failed on $instance"
          return 1
        fi
      fi

      return 0
    else
      log "WARNING" "Failed to reload PM2 on $instance (attempt $attempt/$MAX_RETRIES)"
      cat "/tmp/pm2_reload_${instance}.log" >>"$LOG_FILE"

      if [ $attempt -lt $MAX_RETRIES ]; then
        local backoff=$((RETRY_DELAY * 2 ** (attempt - 1)))
        log "INFO" "Retrying in ${backoff}s..."
        sleep $backoff
      fi
    fi

    ((attempt++))
  done

  log "ERROR" "Failed to reload PM2 on $instance after $MAX_RETRIES attempts"
  return 1
}

# Check dependencies with spinner
check_dependency() {
  local cmd=$1
  log "INFO" "Checking for $cmd..."
  if ! command -v $cmd &>/dev/null; then
    log "ERROR" "$cmd is required"
    return 1
  fi
  return 0
}

# Main execution
main() {
  # Load config first (can be overridden by command line args)
  [ -f "$CONFIG_FILE" ] && load_config

  # Parse command line arguments
  parse_args "$@"

  # Set up trap for cleanup
  trap cleanup SIGINT SIGTERM

  # Banner
  log "INFO" "🚀 PM2 Reload Manager"
  log "INFO" "Environment: $ENV_NAME"
  log "INFO" "AWS Profile: $AWS_PROFILE"
  log "INFO" "SSH Key: $SSH_KEY"
  log "INFO" "Mode: $([ "$PARALLEL_MODE" = true ] && echo "Parallel" || echo "Sequential")"
  [ "$ROLLING_RELOAD" = true ] && log "INFO" "Rolling reload enabled"
  [ "$DRY_RUN" = true ] && log "INFO" "DRY RUN MODE - No changes will be made"

  # Interactive mode confirmation if not using --no-prompt
  if [ -z "$NO_PROMPT" ]; then
    read -p "Continue with these settings? (Y/n/edit/save) " -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
      save_config
      log "SUCCESS" "Configuration saved to $CONFIG_FILE"
      read -p "Continue with operation? (Y/n) " -r
      [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]] && exit 0
    elif [[ $REPLY =~ ^[Ee]$ ]]; then
      read -p "Environment name [$ENV_NAME]: " new_env
      read -p "AWS Profile [$AWS_PROFILE]: " new_profile
      read -p "SSH Key path [$SSH_KEY]: " new_key
      read -p "Parallel mode (y/N): " parallel
      read -p "Rolling reload (y/N): " rolling
      ENV_NAME=${new_env:-$ENV_NAME}
      AWS_PROFILE=${new_profile:-$AWS_PROFILE}
      SSH_KEY=${new_key:-$SSH_KEY}
      [[ $parallel =~ ^[Yy]$ ]] && PARALLEL_MODE=true || PARALLEL_MODE=false
      [[ $rolling =~ ^[Yy]$ ]] && ROLLING_RELOAD=true || ROLLING_RELOAD=false
      [ "$ROLLING_RELOAD" = true ] && PARALLEL_MODE=false
    elif [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
      log "INFO" "Aborted."
      exit 0
    fi
  fi

  # Validate SSH key exists
  if [ ! -f "${SSH_KEY}" ]; then
    log "ERROR" "SSH key not found at ${SSH_KEY}"
    exit 1
  fi

  # Check SSH key permissions
  KEY_PERMS=$(stat -c "%a" "${SSH_KEY}")
  if [ "$KEY_PERMS" != "600" ]; then
    log "WARNING" "Fixing SSH key permissions..."
    chmod 600 "${SSH_KEY}"
  fi

  # Check dependencies
  check_dependency aws || exit 1
  check_dependency eb || exit 1

  # Fetch instances
  log "INFO" "Fetching instances..."

  if [ "$DRY_RUN" = true ]; then
    log "INFO" "[DRY RUN] Would fetch instances from $ENV_NAME environment"
    # Mock instances for dry run
    INSTANCES="i-0123456789abcdef0 i-0123456789abcdef1 i-0123456789abcdef2"
  else
    INSTANCES=$(aws elasticbeanstalk describe-environment-resources \
      --environment-name "$ENV_NAME" \
      --profile "$AWS_PROFILE" \
      --query 'EnvironmentResources.Instances[*].Id' \
      --output text)
  fi

  if [ -z "$INSTANCES" ]; then
    log "ERROR" "No instances found in $ENV_NAME environment"
    exit 1
  fi

  # Convert to array
  readarray -t INSTANCE_ARRAY <<<"$(echo "$INSTANCES" | tr '\t' '\n')"
  INSTANCE_COUNT=${#INSTANCE_ARRAY[@]}

  log "SUCCESS" "Found $INSTANCE_COUNT instances"

  # Ask if user wants to select specific instances (if interactive)
  SELECTED_INSTANCES=()

  if [ -z "$NO_PROMPT" ]; then
    log "INFO" "Instance Selection:"
    echo "1) Reload all instances"
    echo "2) Select specific instances"
    read -p "Select option [1/2]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[2]$ ]]; then
      # Decide whether to use GUI selection or text selection
      if [ "$GUI_SELECT" = true ]; then
        # Try to use a TUI tool if available
        detect_terminal_ui

        if [ "$TUI_TOOL" != "none" ] && use_tui_selection; then
          # TUI selection was successful
          :
        else
          # Fall back to text-based selection if GUI selection failed
          log "WARNING" "GUI selection requested but no suitable tools found"
          log "INFO" "Falling back to text-based selection"
          use_text_selection
        fi
      else
        # Default to text-based selection
        use_text_selection
      fi
    else
      # Select all instances
      SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
    fi
  fi

  # Track results
  SUCCESS_COUNT=0
  FAILED_INSTANCES=()
  TOTAL_START_TIME=$(date +%s)

  set +e

  # Execute reloads based on selected mode
  if [ "$ROLLING_RELOAD" = true ]; then
    # Rolling reload - one at a time with health check
    log "INFO" "Running in rolling reload mode..."
    for instance in "${SELECTED_INSTANCES[@]}"; do
      reload_instance "$instance"
      if [ $? -eq 0 ]; then
        ((SUCCESS_COUNT++))
      else
        FAILED_INSTANCES+=("$instance")
      fi
    done
  elif [ "$PARALLEL_MODE" = true ]; then
    # Parallel execution
    log "INFO" "Running in parallel mode..."
    PIDS=()
    INSTANCE_MAP=()

    for instance in "${SELECTED_INSTANCES[@]}"; do
      reload_instance "$instance" &
      pid=$!
      PIDS+=($pid)
      INSTANCE_MAP[$pid]=$instance
    done

    # Wait for all processes and collect results
    for pid in "${PIDS[@]}"; do
      wait $pid
      if [ $? -eq 0 ]; then
        ((SUCCESS_COUNT++))
      else
        FAILED_INSTANCES+=("${INSTANCE_MAP[$pid]}")
      fi
    done
  else
    # Sequential execution
    log "INFO" "Running in sequential mode..."
    for instance in "${SELECTED_INSTANCES[@]}"; do
      reload_instance "$instance"
      if [ $? -eq 0 ]; then
        ((SUCCESS_COUNT++))
      else
        FAILED_INSTANCES+=("$instance")
      fi
    done
  fi

  set -e

  TOTAL_END_TIME=$(date +%s)
  TOTAL_DURATION=$((TOTAL_END_TIME - TOTAL_START_TIME))

  # Report results
  log "INFO" "-------- Summary --------"
  log "INFO" "Total instances: ${#SELECTED_INSTANCES[@]}"
  log "SUCCESS" "Successful reloads: $SUCCESS_COUNT"
  log "INFO" "Total duration: ${TOTAL_DURATION}s"
  log "INFO" "Mode: $([ "$PARALLEL_MODE" = true ] && echo "Parallel" || [ "$ROLLING_RELOAD" = true ] && echo "Rolling" || echo "Sequential")"

  if [ ${#FAILED_INSTANCES[@]} -gt 0 ]; then
    log "ERROR" "Failed instances: ${FAILED_INSTANCES[*]}"

    # Offer retry for failed instances if interactive
    if [ -z "$NO_PROMPT" ] && [ $SUCCESS_COUNT -lt ${#SELECTED_INSTANCES[@]} ]; then
      read -p "Retry failed instances? (y/N) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Set ENV_NAME for the new execution
        exec "$0" -e "$ENV_NAME" -p "$AWS_PROFILE" -k "$SSH_KEY" \
          $([ "$PARALLEL_MODE" = true ] && echo "-a" || echo "-s") \
          $([ "$ROLLING_RELOAD" = true ] && echo "-r")
      fi
    fi
    exit 1
  else
    log "SUCCESS" "🎉 All instances successfully reloaded!"
  fi

  # Cleanup temp logs
  rm -f /tmp/pm2_reload_*.log
}

# Add this new function to encapsulate the text-based selection
use_text_selection() {
  # Show instances with numbers
  select_instances() {
    log "INFO" "Text-based instance selection"
    log "INFO" "Available instances:"
    for i in "${!INSTANCE_ARRAY[@]}"; do
      echo -e "$((i + 1))) ${BLUE}${INSTANCE_ARRAY[$i]}${NC}"
    done

    echo -e "\nEnter instance numbers to reload (space-separated, e.g., '1 3 4')"
    echo -e "Or press Enter to select all"
    read -p "> " SELECTION

    if [ -z "$SELECTION" ]; then
      # Select all if nothing entered
      SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
      return 0
    else
      # Process selection
      local has_valid_selection=false
      SELECTED_INSTANCES=()

      for num in $SELECTION; do
        if [ "$num" -le "$INSTANCE_COUNT" ] && [ "$num" -gt 0 ]; then
          SELECTED_INSTANCES+=("${INSTANCE_ARRAY[$((num - 1))]}")
          has_valid_selection=true
        else
          log "ERROR" "Invalid selection: $num"
        fi
      done

      # If no valid instances were selected, ask again
      if [ "$has_valid_selection" = false ]; then
        log "WARNING" "No valid instances selected. Please try again."
        return 1
      fi

      return 0
    fi
  }

  # Keep asking until valid selection is made
  while ! select_instances; do
    # Loop continues until valid selection
    :
  done
}

# Run main function with all arguments
main "$@"
