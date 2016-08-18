#!/usr/bin/env bash

main ()
{
    eval $(config config.yml)
    start_log
    set_list
    set_index_map
    poll_github
}

poll_github ()
{
    THREAD_MAX=$(expr $(ulimit -a|grep '\-u'|awk '{print $5}') / 6 )
    if [ -z "$THREAD_LIMIT" ]; then
        THREAD_LIMIT=$THREAD_MAX
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Configuring Threads] Thread limit is unthrottled, setting to max of: $THREAD_LIMIT\" }"| tee -a "$LOG"
    else
        if [[ "$THREAD_LIMIT" -lt 1  || "$THREAD_LIMIT" -gt "$THREAD_MAX" ]]; then
            THREAD_LIMIT=$THREAD_MAX
            echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Configuration Error] Thread limit is too high or too low, reverting to max of: $THREAD_LIMIT\" }"| tee -a "$LOG"
        fi
    fi

    #POLL ORGS
    for og in ${ORGS[@]}; do
        key="${UUID["$og"]}"

        if [ "${#PID[@]}" -eq "$THREAD_LIMIT" ]; then
            until [ "${#PID[@]}" -lt "$THREAD_LIMIT" ]; do
                for ui in "${UUID[@]}"; do
                    if [ "$(grep "$ui" "$LOG")" ]; then
                        unset PID[$ui]
                    fi
                done
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[THREAD MAX]: Thread Maximum Limit Reached: $THREAD_LIMIT\" }"
                sleep 2
             done
        else
            if [ "$LOG_LEVEL" -ge 1 ]; then
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Polling data] for organization: $og\" }" | tee -a "$LOG"
            fi
            POLL[$key]="$key"
            github_org "$og" "$key" &>> "$LOG" &
            PID[$key]=$!
        fi
    done

    #POLL REPOS
    for rp in "${REPOS[@]}"; do
        key="${UUID["$rp"]}"

        if [ "${#PID[@]}" -eq "$THREAD_LIMIT" ]; then
            until [ "${#PID[@]}" -lt "$THREAD_LIMIT" ]; do
                for ui in "${UUID[@]}"; do
                    if [ "$(grep "$ui" "$LOG")" ]; then
                        unset PID[$ui]
                    fi
                done
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[THREAD MAX]: Thread Maximum Limit Reached: $THREAD_LIMIT\" }"
                sleep 2
             done
        else
            if [ "$LOG_LEVEL" -ge 1 ]; then
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Polling data] for repo: $rp\" }" | tee -a "$LOG"
            fi
            POLL[$key]="$key"
            github_repo "$rp" &>> "$LOG" &
            PID[$key]=$!
        fi
    done

    #WAIT FOR POLLING
    until [ "${#POLL[@]}" -eq 0 ]; do

        for ud in "${UUID[@]}"; do
            if [ "$(grep "$ud" "$LOG")" ]; then
                unset POLL[$ud]
            fi
        done

        if [ "$LOG_LEVEL" -ge 1 ]; then
            local progress=""
            for id in "${POLL[@]}"; do
                for fn in "${!UUID[@]}" ; do
                    if [ "${POLL["$id"]}" == "${UUID["$fn"]}" ]; then
                        progress=$progress"{ \"polling\": \""$fn"\" },"
                    fi
                done
            done
            wait_msg="{ \"timestamp\": \"$(date +%s)\", \"[Waiting on]\": [ "$(echo "$progress"|rev|cut -c 2-|rev)" ] }"
            clear
            echo $wait_msg |jq -Ss .[]
            sleep 2
        fi
    done

    echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"Polling Finished.\" }" | tee -a "$LOG"
}

github_repo ()
{
    repo="$1"
    repo_key="${UUID["$repo"]}"

    if empty "$repo" "repo" ; then
        REPOS[$repo_key]=""
        if [ "$LOG_LEVEL" -ge 3 ]; then
            echo "******REPO \"$repo\" NOT-FOUND *********" >> "$LOG"
        fi
    else
        REPOS[$repo_key]="$(curl -skL -H "$github_header" "https://$github_api/repos/$1"|jq '. + {type: "repository", source: "github"}'| jq -s . | jq -c '.[] as $data|{ "index": { "_index": "github", "_type": "repository", "_id": ($data.source + "-" + $data.type + "-" + $data.owner.login + "-" + $data.name )}}, $data')"

        if empty "$repo" "commits" ; then
            COMMITS[$repo_key]=""
            if [ "$LOG_LEVEL" -ge 3 ]; then
                echo "******COMMITS EMPTY*********" >> "$LOG"
            fi
        else
            COMMITS[$repo_key]="$(concat_data "$repo" "commits")"
        fi

        if empty "$repo" "issues" ; then
            ISSUES[$repo_key]=""
            if [ "$LOG_LEVEL" -ge 3 ]; then
                echo "******ISSUES EMPTY*********" >> "$LOG"
            fi
        else
            ISSUES[$repo_key]="$(concat_data "$repo" "issues")"
        fi
    fi

    index_data "$repo" "$repo_key" "repo"
}

github_org ()
{
    org="$1"
    org_key="$2"

    ORGS[$org_key]="$(curl -skL -H "$github_header" "https://$github_api/orgs/$org"|jq '. + {source: "github"}' | jq -c '. as $data|{ "index": { "_index": "github", "_type": "organization", "_id": ($data.source + "-" + $data.type + "-" + $data.login )}}, $data')"
    if [ "$LOG_LEVEL" -ge  1 ]; then
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Gathering Members]: of organization: $org\" }"
    fi
    member_pages="$(paginate "orgs/$org/members")"

    if [ -n "$member_pages" ]; then
        if [ "$LOG_LEVEL" -ge  1 ]; then
            echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Gathering members]: from organization: $org\" }"
        fi
        for member in $(echo "$member_pages"| jq -s . |jq .[].login|sed s/\"//g) ; do
            MEMBERS[$member]="$(curl -skL -H "$github_header" "https://$github_api/users/$member"|jq '. + {source: "github"}' | jq -c '. as $data|{ "index": { "_index": "github", "_type": "organization", "_id": ($data.source + "-" + $data.type + "-" + $data.login )}}, $data')"
        done
    fi

    index_data "$org" "$org_key" "org"
}

concat_data ()
{

    full_name="$1"
    owner="$(echo "$full_name"| awk -F "/" '{print $1}')"
    name="$(echo "$full_name"| awk -F "/" '{print $2}')"

    case "$2" in
        "commits")
          pages="$(paginate "repos/$full_name/commits")"
          data="$(echo "$pages" |jq . |jq --arg full_name "$full_name" --arg owner "$owner" --arg name "$name" '. + {full_name: $full_name, repository: $name, login: $owner, type: "commit", source: "github" }' | jq -s . | jq -c '.[] as $data|{ "index": { "_index": "github", "_type": "commit", "_id": ($data.source + "-" + $data.type + "-" + $data.login + "-" + $data.repository + "-" + $data.sha)}}, $data')"
          ;;
        "issues")
          pages="$(paginate "repos/$full_name/issues")"
          data="$(echo "$pages" |jq . |jq --arg full_name "$full_name" --arg owner "$owner" --arg name "$name" '. + {full_name: $full_name, repository: $name, login: $owner, type: "issue", source: "github" }'  | jq -s . | jq -c '.[] as $data|{ "index": { "_index": "github", "_type": "issue", "_id": ($data.source + "-" + $data.type + "-" + $data.login + "-" + $data.repository + "-" + ($data.number|tostring))}}, $data')"
          ;;
        "members")
          pages="$(paginate "users/$full_name/members")"
          data="$(echo "$pages" |jq . |jq '. + {source: "github" }'  | jq -s . | jq -c '.[] as $data|{ "index": { "_index": "github", "_type": "issue", "_id": ($data.source + "-" + $data.type + "-" + $data.login)}}, $data')"
          ;;
    esac

    echo "$data"
}

index_data ()
{
    name="$1"
    key="$2"
    type="$3"

    case "$type" in
        "repo")
          DATA=("${COMMITS[$key]}" "${ISSUES[$key]}" "${REPOS[$key]}")
          ;;
        "org")
          DATA=("${ORGS[$key]}" "${MEMBERS[@]}")
          ;;
    esac

    for data in "${DATA[@]}"; do

        if [ -n "$data" ]; then
            if [ "$LOG_LEVEL" -ge 2 ]; then
                echo "$data" | curl -s --header "Transfer-Encoding: chunked" -XPOST $ELASTIC/_bulk?pretty=true --data-binary @-
            else
                echo "$data" | curl -s --header "Transfer-Encoding: chunked" -XPOST $ELASTIC/_bulk?pretty=true --data-binary @- &>> /dev/null
            fi
        fi

        if [ "$LOG_LEVEL" -ge 3 ]; then
            echo "{ \"raw\": \"$data\" }"
        fi
    done

    echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Polling Complete]: for _id: $name with Polling UUID: $key\" }"
}

paginate ()
{
    pg_num=1
    fetch='[fetch]'
    endpoint="$1"
    argument="$(echo "$endpoint" | awk -F '?' '{print $2}')"
    primary_endpoint="$(echo "$endpoint" | awk -F '?' '{print $1}')"

    if [ "$LOG_LEVEL" -ge  1 ]; then
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"Paginating endpoint: $endpoint\" }" &>> "$LOG"
    fi

    until [ -z "$fetch" ]; do
        if [ -z "$argument" ]; then
            fetch="$(curl -skL -H "Authorization: token $github_token" "https://$github_api/$endpoint?page=$pg_num"| jq .[])"
        else
            fetch="$(curl -skL -H "Authorization: token $github_token" "https://$github_api/$primary_endpoint?page=$pg_num&$argument"| jq .[])"
        fi
        if [ -n "$fetch" ]; then
            pages=$pages$fetch
        fi
        pg_num=$(expr $pg_num + 1)
    done

    echo "$pages"
}

set_list ()
{
    #Meta-Data Arrays
    declare -gA UUID
    declare -gA POLL
    declare -gA PID
    #Data Arrays
    ## API Endpoints
    declare -a ENDPOINTS
    ## Repo Data
    declare -gA REPOS
    declare -gA COMMITS
    declare -gA ISSUES
    ## Org Data
    declare -gA ORGS
    declare -gA MEMBERS

    if [ -z "$github_repo" ]; then
        if [ -z "$github_org" ]; then
            if [ "$LOG_LEVEL" -ge  1 ]; then
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Gathering Organizations]: available with token: $github_token\" }" | tee -a "$LOG"
            fi

            org_pages="$(paginate "user/orgs")"
            for org in $(echo "$org_pages"|jq -s . |jq .[].login|sed s/\"//g) ; do
                uuid="$(uuidgen)"
                UUID[$org]="$uuid"
                ORGS[$uuid]="$org"
                ENDPOINTS+=("orgs/$org/repos")
            done
        else
            ENDPOINTS+=("orgs/$github_org/repos")
            uuid="$(uuidgen)"
            UUID[$github_org]="$uuid"
            ORGS[$uuid]="$github_org"
        fi

        for ep in "${ENDPOINTS[@]}"; do
            if [ "$LOG_LEVEL" -ge  1 ]; then
                echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Gathering repos]: from endpoint: $ep\" }" | tee -a "$LOG"
            fi

            repo_names="$(paginate "$ep" | jq .full_name | sed s/\"//g)"
            for name in $repo_names; do
                if [ -z "${UUID["$name"]}" ]; then
                    uuid="$(uuidgen)"
                    UUID[$name]="$uuid"
                    REPOS[$uuid]="$name"
                fi
            done
        done
        unset ENDPOINTS
    else
        uuid="$(uuidgen)"
        UUID[$github_repo]="$uuid"
        REPOS[$uuid]="$github_repo"
    fi
}

set_index_map ()
{
    if [ "$LOG_LEVEL" -ge 2 ]; then
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Setting index map] in elasticsearch for index: github\" }"
        cat "$github_mappings" | curl -s -XPOST $ELASTIC/_template/repository?pretty=true --data-binary @- &>>"$LOG"
    else
        cat "$github_mappings" | curl -s -XPOST $ELASTIC/_template/repository?pretty=true --data-binary @- &> /dev/null
    fi
}

empty ()
{
    case "$2" in
        "commits")
          test="$(curl -skL -H "$github_header" "https://$github_api/repos/$1/$2")"
          if [ "$(echo "$test"|grep -F '"message": "Git Repository is empty."')" ] ; then return 0; else return 1; fi
          ;;
        "issues")
          test="$(curl -skL -H "$github_header" "https://$github_api/repos/$1/$2")"
          if [ ! "$(echo "$test"|grep -v ^\\[\\]$)" ] ; then return 0; else return 1; fi
          ;;
        "repo")
          test="$(curl -skL -H "$github_header" "https://$github_api/repos/$1")"
          if [ "$(echo "$test"|grep -F '"message": "Not Found"')" ] ; then return 0; else return 1; fi
          ;;
    esac

    if [ "$LOG_LEVEL" -ge 3 ]; then
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[TEST-EMPTY $1 $2]: $test \" }" &>> "$LOG"
    fi

}

config ()
{
    local prefix=$2
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*'
    fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
    awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
    }'
}

start_log ()
{
    if [ "$TRUNCATE" == true ] ; then echo > "$LOG"
        if [ "$?" -ne 0 ]; then fatal=true ;fi
    elif [ -f "$LOG" ]; then
        mv "$LOG" "$LOG-"$(date +%s)""
        if [ "$?" -ne 0 ]; then fatal=true ;fi
    else
        touch "$LOG"
        if [ "$?" -ne 0 ]; then fatal=true ;fi
    fi

    if [ "$fatal" == true ]; then
        echo "Fatal error, cannot truncate log"  && exit 1
    else
        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"Polling started...\" }"| tee -a "$LOG"
    fi

}

#octokit ()
#{
#    export octokit_api=$github_octokit
#    export octokit_arg0=$1
#    export octokit_arg1=$2
#
#    /usr/bin/ruby <<-OCTOKIT
#
#    require "octokit"
#    Octokit.configure do |c|
#      c.api_endpoint = ENV["octokit_api"]
#      c.auto_paginate = true
#    end
#
#    case ENV["octokit_arg0"]
#      when "repos"
#        puts Octokit.repositories.length
#      when "user_repos"
#        puts Octokit.repositories(ENV["octokit_arg1"]).length
#      when "org_repos"
#        puts Octokit.organization_repositories(ENV["octokit_arg1"]).length
#      when "commits"
#        puts Octokit.commits(ENV["octokit_arg1"]).length
#      when "issues"
#        puts Octokit.list_issues(ENV["octokit_arg1"]).length
#      else
#       puts "Invalid type. See https://github.com/swizzley/octokit.rb/tree/master/lib/octokit/client"
#       exit
#    end
#
#OCTOKIT
#
#}

#concat_pages ()
#{
#    PG_SIZE=30
#    endpoint="$1"
#    octokit="$2"
#    octoparam="$3"
#    uid="$4"
#
#    if [ "$LOG_LEVEL" -ge 2 ]; then
#        echo "{ \"timestamp\": \"$(date +%s)\", \"msg\": \"[Pagination]: Octokit is now caching the number of pages to fetch the '$octoparam' data for '$endpoint'.\" }" &>> "$LOG"
#    fi
#
#    if [ -n "$octoparam" ]; then
#        length=$(expr $(octokit $octokit $octoparam) + 0)
#    else
#        length=$(expr $(octokit $octokit) + 0)
#    fi
#
#    if [ "$length" -le $PG_SIZE ]; then
#        pages=1
#    else
#        if [ "$(expr $length % $PG_SIZE)" -eq 0 ]; then
#            pages=$(expr $length / $PG_SIZE)
#        else
#            pages=$(expr $(expr $length / $PG_SIZE) + 1)
#        fi
#    fi
#
#    for page_num in $(seq 1 $pages); do
#        if [ "$(echo "$endpoint"|grep ?)" ]; then
#            url="https://$github_api/$endpoint\&page=$page_num"
#        else
#            url="https://$github_api/$endpoint?page=$page_num"
#        fi
#
#        if [ -n "$uid" ]; then
#            page_array="$(echo "$uid"| sed s/-//g|sed s/[0-9]//g)"
#            page_data="$(curl -skL -H "$github_header" "$url")"
#            declare -gA $page_array
#            eval "$(eval "echo "\$page_array[\$page_num]='\$page_data' )"
#        else
#            declare -a DAT[$page_num]="$(curl -skL -H "$github_header" "$url")"
#        fi
#    done
#
#    if [ -n "$uid" ]; then
#        echo "$( eval echo "\${$page_array[@]}")"
#        unset "$( eval echo "\$page_array")"
#    else
#        echo "$(echo "${DAT[@]}"|jq -c .)"
#    fi
#}

main
