#!/bin/sh
OUTPUTFILE=/tmp/desec/output
OUTPUT=""
DRYRUN=
set -e  # Exit script on error

# Function to display environment variables
echo_vars() {
    echo "token: $TOKEN, token-file: $TOKEN_FILE, BLOCKING: $BLOCKING, DEBUG_HTTP: $DEBUG_HTTP, DOMAIN: $DOMAIN, TYPE: $TYPE, SUBNAME: $SUBNAME, RECORD: $RECORD, TTL: $TTL"
}

# Function to display help message
show_help() {
    cat << EOF
Usage: desec [-h] [-V] [--token TOKEN | --token-file TOKEN_FILE] [--non-blocking] [--blocking] [--debug-http] action ...

A simple deSEC.io API client

Positional arguments:
  action:
    get-records    List all records of a domain
    add-record     Add a record set to the domain
    export-zone    export all records into a zone file
	list-domains
	domain-info
	change-record PATCH
	delete-record
	update-record
	
Options:
  -h, --help        Show this help message and exit
  -V, --version     Show program's version number and exit
  --token TOKEN     API authentication token
  --token-file FILE File containing the API authentication token
  --non-blocking    Return an error if API rate limit is reached
  --blocking        Wait and retry if API rate limit is reached (default)
  --debug-http      Print HTTP request/response details
  --dryrun          Do not call API (simulate only)
EOF
    exit 0
}

# Function to check mandatory arguments
check_mandatory_args() {
    local missing=""
    for arg in "$@"; do
        if [ -z "$(eval echo \$$arg)" ]; then
            missing="$missing $arg"
        fi
    done
    if [ -n "$missing" ]; then
        echo "Missing arguments:$missing"
        exit 1
    fi
}

# Function to show version
show_version() {
    echo "desec version 1.0"
    exit 0
}
action_export_zone(){

 API_CALL="curl https://desec.io/api/v1/domains/$DOMAIN/zonefile/ \
        --header \"Authorization: Token $TOKEN\" "
    run_api
	cat $OUTPUTFILE

}
action_list_domains(){

 API_CALL="curl https://desec.io/api/v1/domains/\
        --header \"Authorization: Token $TOKEN\" "
    run_api
	 cat $OUTPUTFILE|readable_json
	 #sed 's/{"created"/\n&/g' $OUTPUTFILE |  sed  -E '1d;s/(.*\"name":")(.*)("\,"minimum.*)/\2/'

}
action_domain_info(){
echo "DOMINF"
 API_CALL="curl https://desec.io/api/v1/domains/$DOMAIN/\
        --header \"Authorization: Token $TOKEN\" "
    run_api
	echo $API_CALL
	 cat $OUTPUTFILE|readable_json
	 #sed 's/{"created"/\n&/g' $OUTPUTFILE |  sed  -E '1d;s/(.*\"name":")(.*)("\,"minimum.*)/\2/'

}

# Function to make API call to add a record
action_add_record() {
    #[ -z "$SUBNAME" ] && SUBNAME="@"
    [ "$TYPE" = "TXT" ] && RECORD="\\\"$RECORD\\\""

    local json_data="{\"subname\": \"$SUBNAME\", \"type\": \"$TYPE\", \"ttl\": $TTL, \"records\": [\"$RECORD\"]}"
    API_CALL="curl -X POST https://desec.io/api/v1/domains/$DOMAIN/rrsets/ \
        --header \"Authorization: Token $TOKEN\" \
        --header \"Content-Type: application/json\" \
        --data '$json_data'"
    run_api
	echo $OUTPUT
}
action_delete_record() {
    RECORD=""
	TTL=3600
	action_change_record
}
action_change_record() {
    #[ -z "$SUBNAME" ] && SUBNAME="@"
    [ "$TYPE" = "TXT" ] && RECORD="\\\"$RECORD\\\""
    # Delete record by settinge empty record
	if [ "$RECORD" = "" ]; then
	#TODO append each variable if non-zerro
		local json_data="[{\"subname\": \"$SUBNAME\", \"type\": \"$TYPE\", \"ttl\": $TTL, \"records\": []}]"
	else
		local json_data="[{\"subname\": \"$SUBNAME\", \"type\": \"$TYPE\", \"ttl\": $TTL, \"records\": [\"$RECORD\"]}]"
	fi
    API_CALL="curl -X PATCH https://desec.io/api/v1/domains/$DOMAIN/rrsets/ \
        --header \"Authorization: Token $TOKEN\" \
        --header \"Content-Type: application/json\" \
        --data '$json_data'"
    run_api
cat $OUTPUTFILE|readable_json

}
action_get_records() {
    [ -z "$SUBNAME" ] && SUBNAME="@"
    [ "$TYPE" = "TXT" ] && RECORD="\\\"$RECORD\\\""

    API_CALL="curl https://desec.io/api/v1/domains/$DOMAIN/rrsets/ \
        --header \"Authorization: Token $TOKEN\" "

    run_api
	cat $OUTPUTFILE
	sed 's/{"created"/\n&/g' $OUTPUTFILE |  sed  -E 's/(.*\"name":")(.*)(","records":\[")(.*)("],"ttl":)(.*),"type":"(.*)",".*}./\2_IFS_\6_IFS_\7_IFS_"\4"/'  |\
	awk -F'_IFS_' '{
		gsub(/\\"/, "_CSV_", $4);
		split($4, a, "\",\"");
		for (i in a) {
			value = a[i];
			# Remove surrounding quotes from all values
			gsub(/(^\")|(\"*$)|_CSV_/, "", value);
			type = $3;
			# Add quotes back only for TXT records
			if (type == "TXT") {
					value = "\"" value "\"";
			}
			print $1" "$2" IN "type" " value;
		}
	}'

}

# Function to execute API call
run_api() {
    
	if [ "$DEBUG_HTTP" = "true" ]; then
        echo "API Call: $API_CALL"
    fi
    if [ -z "$DRYRUN" ]; then
    eval "$API_CALL" -s -o $OUTPUTFILE 
		OUTPUT=$(cat $OUTPUTFILE)
		#echo "HERER: $OUTPUT"
    else
        echo "DRYRUN - API call skipped"
    fi
}
function readable_json(){
awk '
{
  indent = 0
  result = ""
  for (i = 1; i <= length($0); i++) {
    char = substr($0, i, 1)
    if (char ~ /[{\[]/) {
      result = result char "\n" spaces(indent+2)
      indent += 2
    } else if (char ~ /[}\]]/) {
      indent -= 2
      result = result "\n" spaces(indent) char
    } else if (char == ",") {
      result = result ",\n" spaces(indent)
    } else if (char == ":") {
      result = result ": "
    } else {
      result = result char
    }
  }
  print result
}

function spaces(n) {
  s = ""
  for (j = 0; j < n; j++) s = s " "
  return s
}'
}
# Parse command-line options
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        -V|--version) show_version ;;
        --token) TOKEN="$2"; shift ;;
        --token-file) TOKEN_FILE="$2"; shift ;;
        --non-blocking) BLOCKING="false" ;;
        --blocking) BLOCKING="true" ;;
        --debug-http) DEBUG_HTTP="true" ;;
        --dryrun) DRYRUN="true" ;;
        *) ACTION="$1";  break ;;
    esac
    shift
done

# Parse remaining arguments

while [ "$#" -gt 0 ]; do
    case "$1" in
        -t|--type) TYPE="$2"; shift;;
        -s|--subname) SUBNAME="$2"; shift ;;
        -r|--record) RECORD="$2"; shift ;;
        --ttl) TTL="$2"; shift ;;
        *) DOMAIN="$1" ;;
    esac
    shift
	
done
# Load token from file if not provided
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE")
fi
# Ensure mandatory arguments are set
check_mandatory_args TOKEN ACTION
# Execute action
case "$ACTION" in
    get-records)
     #   echo "Fetching records for domain: $DOMAIN"
		action_get_records
        ;;
    add-record)
        check_mandatory_args DOMAIN TYPE RECORD
        echo_vars
        action_add_record
        ;;

    change-record)
        check_mandatory_args DOMAIN TYPE
        echo_vars
        action_change_record
        ;;
    delete-record)
        check_mandatory_args DOMAIN TYPE
		echo_vars
        action_delete_record
        ;;
    update-record)
        check_mandatory_args DOMAIN TYPE RECORD
        echo_vars
        action_update_record
        ;;
    export-zone)
        check_mandatory_args DOMAIN
        #echo_vars
        action_export_zone
        ;;     
    list-domains)
        action_list_domains
        ;;
    domain-info)
        action_domain_info
        ;;
    *)
        echo "Unknown action: $ACTION"
        show_help
        ;;
esac

# Display debug/blocking mode info
#[ "$DEBUG_HTTP" = "true" ] && echo "Debug HTTP is enabled."
#[ "$BLOCKING" = "true" ] && echo "Blocking mode: Retrying on rate limit." || echo "Non-blocking mode: Error on rate limit."
