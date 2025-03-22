#!/bin/bash
set -e  # Exit on error

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Make environment configurable
ENV_NAME="${1:-Kutubee2-core-prod}"
AWS_PROFILE="${2:-admin-kutubee-ammar}"
SSH_KEY="${3:-/home/ammaro/.ssh/LiveKububee.pem}"

# Interactive mode confirmation
echo -e "${YELLOW}🚀 PM2 Reload Manager${NC}"
echo "Environment: $ENV_NAME"
echo "AWS Profile: $AWS_PROFILE"
echo "SSH Key: $SSH_KEY"
read -p "Continue with these settings? (Y/n/edit) " -n 1 -r
echo
if [[ $REPLY =~ ^[Ee]$ ]]; then
    read -p "Environment name [$ENV_NAME]: " new_env
    read -p "AWS Profile [$AWS_PROFILE]: " new_profile
    read -p "SSH Key path [$SSH_KEY]: " new_key
    ENV_NAME=${new_env:-$ENV_NAME}
    AWS_PROFILE=${new_profile:-$AWS_PROFILE}
    SSH_KEY=${new_key:-$SSH_KEY}
elif [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
    echo "Aborted."
    exit 1
fi

# Function to reload PM2 on a single instance
reload_instance() {
    local instance=$1
    local START_TIME=$(date +%s)
    
    echo -e "\n${YELLOW}🔄 Reloading PM2 on instance $instance...${NC}"
    
    eb ssh --profile "$AWS_PROFILE" "$ENV_NAME" --instance "$instance" \
        --custom "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
        -c "sudo su - webapp -c 'pm2 reload all'" &> /tmp/pm2_reload_${instance}.log
    
    local EXIT_CODE=$?
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully reloaded PM2 on $instance (${DURATION}s)${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to reload PM2 on $instance (${DURATION}s)${NC}"
        cat /tmp/pm2_reload_${instance}.log
        return 1
    fi
}

# Validate SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo -e "${RED}Error: SSH key not found at ${SSH_KEY}${NC}" >&2
    exit 1
fi

# Check SSH key permissions
KEY_PERMS=$(stat -c "%a" "${SSH_KEY}")
if [ "$KEY_PERMS" != "600" ]; then
    echo -e "${YELLOW}Warning: Fixing SSH key permissions...${NC}"
    chmod 600 "${SSH_KEY}"
fi

# Check dependencies with spinner
check_dependency() {
    local cmd=$1
    echo -n "Checking for $cmd... "
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}❌${NC}"
        echo -e "${RED}Error: $cmd is required${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✓${NC}"
    return 0
}

check_dependency aws || exit 1
check_dependency eb || exit 1

# Fetch instances first
echo -e "\n${YELLOW}📡 Fetching instances...${NC}"
INSTANCES=$(aws elasticbeanstalk describe-environment-resources \
    --environment-name "$ENV_NAME" \
    --profile "$AWS_PROFILE" \
    --query 'EnvironmentResources.Instances[*].Id' \
    --output text)

if [ -z "$INSTANCES" ]; then
    echo -e "${RED}Error: No instances found in $ENV_NAME environment${NC}" >&2
    exit 1
fi

# Convert to array
readarray -t INSTANCE_ARRAY <<< "$(echo "$INSTANCES" | tr '\t' '\n')"
INSTANCE_COUNT=${#INSTANCE_ARRAY[@]}

echo -e "${GREEN}Found $INSTANCE_COUNT instances${NC}"

# Ask if user wants to select specific instances
echo -e "\n${YELLOW}Instance Selection:${NC}"
echo "1) Reload all instances"
echo "2) Select specific instances"
read -p "Select option [1/2]: " -n 1 -r
echo

SELECTED_INSTANCES=()

if [[ $REPLY =~ ^[2]$ ]]; then
    # Show instances with numbers
    echo -e "\n${BLUE}Available instances:${NC}"
    for i in "${!INSTANCE_ARRAY[@]}"; do
        echo -e "$((i+1))) ${BLUE}${INSTANCE_ARRAY[$i]}${NC}"
    done
    
    echo -e "\nEnter instance numbers to reload (space-separated, e.g., '1 3 4')"
    echo -e "Or press Enter to select all"
    read -p "> " SELECTION
    
    if [ -z "$SELECTION" ]; then
        # Select all if nothing entered
        SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
    else
        # Process selection
        for num in $SELECTION; do
            if [ "$num" -le "$INSTANCE_COUNT" ] && [ "$num" -gt 0 ]; then
                SELECTED_INSTANCES+=("${INSTANCE_ARRAY[$((num-1))]}")
            else
                echo -e "${RED}Invalid selection: $num${NC}"
            fi
        done
    fi
else
    # Select all instances
    SELECTED_INSTANCES=("${INSTANCE_ARRAY[@]}")
fi

# Show selected instances
echo -e "\n${BLUE}Selected instances to reload:${NC}"
printf '%s\n' "${SELECTED_INSTANCES[@]}"
INSTANCE_COUNT=${#SELECTED_INSTANCES[@]}
echo -e "${GREEN}Total selected: $INSTANCE_COUNT${NC}"

# Ask for execution mode
echo -e "\n${YELLOW}Execution Mode:${NC}"
echo "1) Sequential (one by one)"
echo "2) Parallel (all at once)"
read -p "Select mode [1/2]: " -n 1 -r
echo
PARALLEL_MODE=false
if [[ $REPLY =~ ^[2]$ ]]; then
    PARALLEL_MODE=true
fi

# Ask for confirmation before proceeding
read -p "Proceed with reload? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
    echo "Aborted."
    exit 1
fi

# Track results
SUCCESS_COUNT=0
FAILED_INSTANCES=""
TOTAL_START_TIME=$(date +%s)

set +e

if [ "$PARALLEL_MODE" = true ]; then
    # Parallel execution
    echo -e "${YELLOW}Running in parallel mode...${NC}"
    PIDS=()
    for instance in "${SELECTED_INSTANCES[@]}"; do
        reload_instance "$instance" &
        PIDS+=($!)
    done

    # Wait for all processes and collect results
    for pid in "${PIDS[@]}"; do
        wait $pid
        if [ $? -eq 0 ]; then
            ((SUCCESS_COUNT++))
        else
            FAILED_INSTANCES="$FAILED_INSTANCES $instance"
        fi
    done
else
    # Sequential execution
    echo -e "${YELLOW}Running in sequential mode...${NC}"
    for instance in "${SELECTED_INSTANCES[@]}"; do
        reload_instance "$instance"
        if [ $? -eq 0 ]; then
            ((SUCCESS_COUNT++))
        else
            FAILED_INSTANCES="$FAILED_INSTANCES $instance"
        fi
    done
fi

set -e

TOTAL_END_TIME=$(date +%s)
TOTAL_DURATION=$((TOTAL_END_TIME - TOTAL_START_TIME))

# Report results
echo -e "\n${YELLOW}-------- Summary --------${NC}"
echo "Total instances: $INSTANCE_COUNT"
echo -e "Successful reloads: ${GREEN}$SUCCESS_COUNT${NC}"
echo "Total duration: ${TOTAL_DURATION}s"
echo "Mode: $([ "$PARALLEL_MODE" = true ] && echo "Parallel" || echo "Sequential")"

if [ -n "$FAILED_INSTANCES" ]; then
    echo -e "${RED}Failed instances:$FAILED_INSTANCES${NC}"
    
    # Offer retry for failed instances
    if [ $SUCCESS_COUNT -lt $INSTANCE_COUNT ]; then
        echo
        read -p "Retry failed instances? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            exec "$0" "$ENV_NAME" "$AWS_PROFILE" "$SSH_KEY"
        fi
    fi
    exit 1
else
    echo -e "${GREEN}🎉 All instances successfully reloaded!${NC}"
fi

# Cleanup temp logs
rm -f /tmp/pm2_reload_*.log