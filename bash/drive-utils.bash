#!/usr/bin/env bash

###################################################
# Search for an existing file on gdrive with write permission.
# Globals: 3 variables, 2 functions
#   Variables - API_URL, API_VERSION, ACCESS_TOKEN
#   Functions - _url_encode, _json_value
# Arguments: 4
#   ${1} = file name
#   ${2} = root dir id of file
#   ${3} = mode ( size or md5Checksum or empty )
#   ${4} = if mode = empty, then not required
#             mode = size, then size
#             mode = md5Checksum, then md5sum
# Result: print search response if id fetched
#         check size and md5sum if mode size or md5Checksum
# Reference:
#   https://developers.google.com/drive/api/v3/search-files
###################################################
_check_existing_file() {
    [[ $# -lt 2 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare name="${1}" rootdir="${2}" mode="${3}" param_value="${4}" query search_response id

    "${EXTRA_LOG}" "justify" "Checking if file" " exists on gdrive.." "-" 1>&2
    query="$(_url_encode "name=\"${name}\" and '${rootdir}' in parents and trashed=false")"

    search_response="$(_api_request "${CURL_PROGRESS_EXTRA}" \
        "${API_URL}/drive/${API_VERSION}/files?q=${query}&fields=files(id,name,mimeType${mode:+,${mode}})&supportsAllDrives=true&includeItemsFromAllDrives=true" || :)" && _clear_line 1 1>&2
    _clear_line 1 1>&2

    _json_value id 1 1 <<< "${search_response}" 2>| /dev/null 1>&2 || return 1

    [[ -n ${mode} ]] && {
        [[ "$(_json_value "${mode}" 1 1 <<< "${search_response}")" = "${param_value}" ]] || return 1
    }

    printf "%s\n" "${search_response}"
    return 0
}

###################################################
# Copy/Clone a public gdrive file/folder from another/same gdrive account
# Globals: 6 variables, 6 functions
#   Variables - API_URL, API_VERSION, CURL_PROGRESS, LOG_FILE_ID, QUIET, ACCESS_TOKEN, DESCRIPTION_FILE
#   Functions - _print_center, _check_existing_file, _json_value, _json_escape _bytes_to_human, _clear_line
# Arguments: 5
#   ${1} = update or upload ( upload type )
#   ${2} = file id to upload
#   ${3} = root dir id for file
#   ${4} = name of file
#   ${5} = size of file
#   ${6} = md5sum of file
# Result: On
#   Success - Upload/Update file and export FILE_ID
#   Error - return 1
# Reference:
#   https://developers.google.com/drive/api/v2/reference/files/copy
###################################################
_clone_file() {
    [[ $# -lt 5 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare job="${1}" file_id="${2}" file_root_id="${3}" name="${4}" size="${5}" md5="${6}"
    declare clone_file_post_data clone_file_response readable_size _file_id description escaped_name && STRING="Cloned"
    escaped_name="$(_json_escape j "${name}")" print_name="$(_json_escape p "${name}")" readable_size="$(_bytes_to_human "${size}")"

    # create description data
    [[ -n ${DESCRIPTION_FILE} ]] && {
        : "${DESCRIPTION_FILE//%f/${name}}" && : "${_//%s/${readable_size}}"
        description="$(_json_escape j "${_}")" # escape for json
    }

    clone_file_post_data="{\"parents\": [\"${file_root_id}\"]${description:+,\"description\":\"${description}\"}}"

    _print_center "justify" "${print_name} " "| ${readable_size}" "="

    if [[ ${job} = update ]]; then
        declare file_check_json check_value_type check_value
        case "${CHECK_MODE}" in
            2) check_value_type="size" check_value="${size}" ;;
            3) check_value_type="md5Checksum" check_value="${md5}" ;;
        esac
        # Check if file actually exists.
        if file_check_json="$(_check_existing_file "${escaped_name}" "${file_root_id}")"; then
            if [[ -n ${SKIP_DUPLICATES} ]]; then
                _collect_file_info "${file_check_json}" || return 1
                _clear_line 1
                "${QUIET:-_print_center}" "justify" "${print_name}" " already exists." "=" && return 0
            else
                _print_center "justify" "Overwriting file.." "-"
                { _file_id="$(_json_value id 1 1 <<< "${file_check_json}")" &&
                    clone_file_post_data="$(_drive_info "${_file_id}" "parents,writersCanShare")"; } ||
                    { _error_logging_upload "${print_name}" "${post_data:-${file_check_json}}" || return 1; }
                if [[ ${_file_id} != "${file_id}" ]]; then
                    _api_request -s \
                        -X DELETE \
                        "${API_URL}/drive/${API_VERSION}/files/${_file_id}?supportsAllDrives=true&includeItemsFromAllDrives=true" 2>| /dev/null 1>&2 || :
                    STRING="Updated"
                else
                    _collect_file_info "${file_check_json}" || return 1
                fi
            fi
        else
            "${EXTRA_LOG}" "justify" "Cloning file.." "-"
        fi
    else
        "${EXTRA_LOG}" "justify" "Cloning file.." "-"
    fi

    # shellcheck disable=SC2086 # Because unnecessary to another check because ${CURL_PROGRESS} won't be anything problematic.
    clone_file_response="$(_api_request ${CURL_PROGRESS} \
        -X POST \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "${clone_file_post_data}" \
        "${API_URL}/drive/${API_VERSION}/files/${file_id}/copy?supportsAllDrives=true&includeItemsFromAllDrives=true" || :)"
    for _ in 1 2 3; do _clear_line 1; done
    _collect_file_info "${clone_file_response}" || return 1
    "${QUIET:-_print_center}" "justify" "${print_name} " "| ${readable_size} | ${STRING}" "="
    return 0
}

###################################################
# Create/Check directory in google drive.
# Globals: 3 variables, 3 functions
#   Variables - API_URL, API_VERSION, ACCESS_TOKEN
#   Functions - _url_encode, _json_value, _json_escape
# Arguments: 2
#   ${1} = dir name
#   ${2} = root dir id of given dir
# Result: print folder id
# Reference:
#   https://developers.google.com/drive/api/v3/folder
###################################################
_create_directory() {
    [[ $# -lt 2 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare dirname="${1##*/}" escaped_dirname rootdir="${2}" query search_response folder_id
    escaped_dirname="$(_json_escape j "${dirname}")" print_dirname="$(_json_escape p "${dirname}")"

    "${EXTRA_LOG}" "justify" "Creating gdrive folder:" " ${print_dirname}" "-" 1>&2
    query="$(_url_encode "mimeType='application/vnd.google-apps.folder' and name=\"${escaped_dirname}\" and trashed=false and '${rootdir}' in parents")"

    search_response="$(_api_request "${CURL_PROGRESS_EXTRA}" \
        "${API_URL}/drive/${API_VERSION}/files?q=${query}&fields=files(id)&supportsAllDrives=true&includeItemsFromAllDrives=true" || :)" && _clear_line 1 1>&2

    if ! folder_id="$(printf "%s\n" "${search_response}" | _json_value id 1 1)"; then
        declare create_folder_post_data create_folder_response
        create_folder_post_data="{\"mimeType\": \"application/vnd.google-apps.folder\",\"name\": \"${escaped_dirname}\",\"parents\": [\"${rootdir}\"]}"
        create_folder_response="$(_api_request "${CURL_PROGRESS_EXTRA}" \
            -X POST \
            -H "Content-Type: application/json; charset=UTF-8" \
            -d "${create_folder_post_data}" \
            "${API_URL}/drive/${API_VERSION}/files?fields=id&supportsAllDrives=true&includeItemsFromAllDrives=true" || :)" && _clear_line 1 1>&2
    fi
    _clear_line 1 1>&2

    { folder_id="${folder_id:-$(_json_value id 1 1 <<< "${create_folder_response}")}" && printf "%s\n" "${folder_id}"; } ||
        { printf "%s\n" "${create_folder_response}" 1>&2 && return 1; }
    return 0
}

###################################################
# Get information for a gdrive folder/file.
# Globals: 3 variables, 1 function
#   Variables - API_URL, API_VERSION, ACCESS_TOKEN
#   Functions - _json_value
# Arguments: 2
#   ${1} = folder/file gdrive id
#   ${2} = information to fetch, e.g name, id
# Result: On
#   Success - print fetched value
#   Error   - print "message" field from the json
# Reference:
#   https://developers.google.com/drive/api/v3/search-files
###################################################
_drive_info() {
    [[ $# -lt 2 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare folder_id="${1}" fetch="${2}" search_response

    "${EXTRA_LOG}" "justify" "Fetching info.." "-" 1>&2
    search_response="$(_api_request "${CURL_PROGRESS_EXTRA}" \
        "${API_URL}/drive/${API_VERSION}/files/${folder_id}?fields=${fetch}&supportsAllDrives=true&includeItemsFromAllDrives=true" || :)" && _clear_line 1 1>&2
    _clear_line 1 1>&2

    printf "%b" "${search_response:+${search_response}\n}"
    return 0
}

###################################################
# Extract ID from a googledrive folder/file url.
# Globals: None
# Arguments: 1
#   ${1} = googledrive folder/file url.
# Result: print extracted ID
###################################################
_extract_id() {
    [[ $# = 0 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare LC_ALL=C ID="${1}"
    case "${ID}" in
        *'drive.google.com'*'id='*) ID="${ID##*id=}" && ID="${ID%%\?*}" && ID="${ID%%\&*}" ;;
        *'drive.google.com'*'file/d/'* | 'http'*'docs.google.com'*'/d/'*) ID="${ID##*\/d\/}" && ID="${ID%%\/*}" && ID="${ID%%\?*}" && ID="${ID%%\&*}" ;;
        *'drive.google.com'*'drive'*'folders'*) ID="${ID##*\/folders\/}" && ID="${ID%%\?*}" && ID="${ID%%\&*}" ;;
    esac
    printf "%b" "${ID:+${ID}\n}"
}

###################################################
# Upload ( Create/Update ) files on gdrive.
# Interrupted uploads can be resumed.
# Globals: 8 variables, 11 functions
#   Variables - API_URL, API_VERSION, QUIET, VERBOSE, VERBOSE_PROGRESS, CURL_PROGRESS, LOG_FILE_ID, ACCESS_TOKEN, DESCRIPTION_FILE
#   Functions - _url_encode, _json_value, _json_escape _print_center, _bytes_to_human, _check_existing_file
#               _generate_upload_link, _upload_file_from_uri, _log_upload_session, _remove_upload_session
#               _full_upload, _collect_file_info
# Arguments: 3
#   ${1} = update or upload ( upload type )
#   ${2} = file to upload
#   ${3} = root dir id for file
# Result: On
#   Success - Upload/Update file and export FILE_ID
#   Error - return 1
# Reference:
#   https://developers.google.com/drive/api/v3/create-file
#   https://developers.google.com/drive/api/v3/manage-uploads
#   https://developers.google.com/drive/api/v3/reference/files/update
###################################################
_upload_file() {
    [[ $# -lt 3 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare job="${1}" input="${2}" folder_id="${3}" \
        slug escaped_slug inputname extension inputsize readable_size request_method url postdata uploadlink upload_body mime_type description \
        resume_args1 resume_args2 resume_args3

    slug="${input##*/}" escaped_slug="$(_json_escape j "${slug}")" print_slug="$(_json_escape p "${slug}")"
    inputname="${slug%.*}"
    extension="${slug##*.}"
    inputsize="$(($(wc -c < "${input}")))" && content_length="${inputsize}"
    readable_size="$(_bytes_to_human "${inputsize}")"

    # Handle extension-less files
    [[ ${inputname} = "${extension}" ]] && declare mime_type && {
        mime_type="$(file --brief --mime-type "${input}" || mimetype --output-format %m "${input}")" 2>| /dev/null || {
            "${QUIET:-_print_center}" "justify" "Error: file or mimetype command not found." "=" && printf "\n"
            exit 1
        }
    }

    # create description data
    [[ -n ${DESCRIPTION_FILE} ]] && {
        : "${DESCRIPTION_FILE//%f/${slug}}" && : "${_//%s/${inputsize}}" && : "${_//%m/${mime_type}}"
        description="$(_json_escape j "${_}")" # escape for json
    }

    _print_center "justify" "${print_slug}" " | ${readable_size}" "="

    # Set proper variables for overwriting files
    [[ ${job} = update ]] && {
        declare file_check_json check_value
        case "${CHECK_MODE}" in
            2) check_value_type="size" check_value="${inputsize}" ;;
            3)
                check_value_type="md5Checksum"
                check_value="$(md5sum "${input}")" || {
                    "${QUIET:-_print_center}" "justify" "Error: cannot calculate md5sum of given file." "=" 1>&2
                    return 1
                }
                check_value="${check_value%% *}"
                ;;
        esac
        # Check if file actually exists, and create if not.
        if file_check_json="$(_check_existing_file "${escaped_slug}" "${folder_id}" "${check_value_type}" "${check_value}")"; then
            if [[ -n ${SKIP_DUPLICATES} ]]; then
                # Stop upload if already exists ( -d/--skip-duplicates )
                _collect_file_info "${file_check_json}" "${escaped_slug}" || return 1
                _clear_line 1
                "${QUIET:-_print_center}" "justify" "${print_slug}" " already exists." "=" && return 0
            else
                request_method="PATCH"
                _file_id="$(_json_value id 1 1 <<< "${file_check_json}")" ||
                    { _error_logging_upload "${print_slug}" "${file_check_json}" || return 1; }
                url="${API_URL}/upload/drive/${API_VERSION}/files/${_file_id}?uploadType=resumable&supportsAllDrives=true&includeItemsFromAllDrives=true"
                # JSON post data to specify the file name and folder under while the file to be updated
                postdata="{\"mimeType\": \"${mime_type}\",\"name\": \"${escaped_slug}\",\"addParents\": [\"${folder_id}\"]${description:+,\"description\":\"${description}\"}}"
                STRING="Updated"
            fi
        else
            job="create"
        fi
    }

    # Set proper variables for creating files
    [[ ${job} = create ]] && {
        url="${API_URL}/upload/drive/${API_VERSION}/files?uploadType=resumable&supportsAllDrives=true&includeItemsFromAllDrives=true"
        request_method="POST"
        # JSON post data to specify the file name and folder under while the file to be created
        postdata="{\"mimeType\": \"${mime_type}\",\"name\": \"${escaped_slug}\",\"parents\": [\"${folder_id}\"]${description:+,\"description\":\"${description}\"}}"
        STRING="Uploaded"
    }

    __file="${HOME}/.google-drive-upload/${print_slug}__::__${folder_id}__::__${inputsize}"
    # https://developers.google.com/drive/api/v3/manage-uploads
    if [[ -r "${__file}" ]]; then
        uploadlink="$(< "${__file}")"
        http_code="$(curl --compressed -s -X PUT "${uploadlink}" -o /dev/null --write-out %"{http_code}")" || :
        case "${http_code}" in
            308) # Active Resumable URI give 308 status
                uploaded_range="$(: "$(curl --compressed -s -X PUT \
                    -H "Content-Range: bytes */${inputsize}" \
                    --url "${uploadlink}" --globoff -D - || :)" &&
                    : "$(printf "%s\n" "${_/*[R,r]ange: bytes=0-/}")" && read -r firstline <<< "$_" && printf "%s\n" "${firstline//$'\r'/}")"
                if [[ ${uploaded_range} -gt 0 ]]; then
                    _print_center "justify" "Resuming interrupted upload.." "-" && _newline "\n"
                    content_range="$(printf "bytes %s-%s/%s\n" "$((uploaded_range + 1))" "$((inputsize - 1))" "${inputsize}")"
                    content_length="$((inputsize - $((uploaded_range + 1))))"
                    # Resuming interrupted uploads needs http1.1
                    resume_args1='-s' resume_args2='--http1.1' resume_args3="Content-Range: ${content_range}"
                    _upload_file_from_uri _clear_line
                    _collect_file_info "${upload_body}" "${print_slug}" || return 1
                    _normal_logging_upload
                    _remove_upload_session
                else
                    _full_upload || return 1
                fi
                ;;
            201 | 200) # Completed Resumable URI give 20* status
                upload_body="${http_code}"
                _collect_file_info "${upload_body}" "${print_slug}" || return 1
                _normal_logging_upload
                _remove_upload_session
                ;;
            4[0-9][0-9] | 000 | *) # Dead Resumable URI give 40* status
                _full_upload || return 1
                ;;
        esac
    else
        _full_upload || return 1
    fi
    return 0
}

###################################################
# Sub functions for _upload_file function - Start
# generate resumable upload link
_generate_upload_link() {
    "${EXTRA_LOG}" "justify" "Generating upload link.." "-" 1>&2
    uploadlink="$(_api_request "${CURL_PROGRESS_EXTRA}" \
        -X "${request_method}" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -H "X-Upload-Content-Type: ${mime_type}" \
        -H "X-Upload-Content-Length: ${inputsize}" \
        -d "$postdata" \
        "${url}" \
        -D - || :)" && _clear_line 1 1>&2
    _clear_line 1 1>&2

    case "${uploadlink}" in
        *'ocation: '*'upload_id'*) uploadlink="$(read -r firstline <<< "${uploadlink/*[L,l]ocation: /}" && printf "%s\n" "${firstline//$'\r'/}")" && return 0 ;;
        '' | *) return 1 ;;
    esac

    return 0
}

# Curl command to push the file to google drive.
_upload_file_from_uri() {
    _print_center "justify" "Uploading.." "-"
    # shellcheck disable=SC2086 # Because unnecessary to another check because ${CURL_PROGRESS} won't be anything problematic.
    upload_body="$(_api_request ${CURL_PROGRESS} \
        -X PUT \
        -H "Content-Type: ${mime_type}" \
        -H "Content-Length: ${content_length}" \
        -H "Slug: ${print_slug}" \
        -T "${input}" \
        -o- \
        --url "${uploadlink}" \
        --globoff \
        ${CURL_SPEED} ${resume_args1} ${resume_args2} \
        -H "${resume_args3}" || :)"
    [[ -z ${VERBOSE_PROGRESS} ]] && for _ in 1 2; do _clear_line 1; done && "${1:-:}"
    return 0
}

# logging in case of successful upload
_normal_logging_upload() {
    [[ -z ${VERBOSE_PROGRESS} ]] && _clear_line 1
    "${QUIET:-_print_center}" "justify" "${print_slug} " "| ${readable_size} | ${STRING}" "="
    return 0
}

# Tempfile Used for resuming interrupted uploads
_log_upload_session() {
    [[ ${inputsize} -gt 1000000 ]] && printf "%s\n" "${uploadlink}" >| "${__file}"
    return 0
}

# remove upload session
_remove_upload_session() {
    rm -f "${__file}"
    return 0
}

# wrapper to fully upload a file from scratch
_full_upload() {
    _generate_upload_link || { _error_logging_upload "${print_slug}" "${uploadlink}" || return 1; }
    _log_upload_session
    _upload_file_from_uri
    _collect_file_info "${upload_body}" "${print_slug}" || return 1
    _normal_logging_upload
    _remove_upload_session
    return 0
}
# Sub functions for _upload_file function - End
###################################################

###################################################
# Share a gdrive file/folder
# Globals: 3 variables, 4 functions
#   Variables - API_URL, API_VERSION, ACCESS_TOKEN
#   Functions - _url_encode, _json_value, _print_center, _clear_line
# Arguments: 2
#   ${1} = gdrive ID of folder/file
#   ${2} = Email to which file will be shared ( optional )
# Result: read description
# Reference:
#   https://developers.google.com/drive/api/v3/manage-sharing
###################################################
_share_id() {
    [[ $# -lt 2 ]] && printf "%s: Missing arguments\n" "${FUNCNAME[0]}" && return 1
    declare id="${1}" role="${2:?Missing role}" share_email="${3}"
    declare type="${share_email:+user}" share_post_data share_post_data share_response

    "${EXTRA_LOG}" "justify" "Sharing.." "-" 1>&2
    share_post_data="{\"role\":\"${role}\",\"type\":\"${type:-anyone}\"${share_email:+,\"emailAddress\":\"${share_email}\"}}"

    share_response="$(_api_request "${CURL_PROGRESS_EXTRA}" \
        -X POST \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "${share_post_data}" \
        "${API_URL}/drive/${API_VERSION}/files/${id}/permissions?supportsAllDrives=true&includeItemsFromAllDrives=true" || :)" && _clear_line 1 1>&2
    _clear_line 1 1>&2

    { _json_value id 1 1 <<< "${share_response}" 2>| /dev/null 1>&2 && return 0; } ||
        { printf "%s\n" "Error: Cannot Share." 1>&2 && printf "%s\n" "${share_response}" 1>&2 && return 1; }
}

export -f _check_existing_file \
    _clone_file \
    _create_directory \
    _drive_info \
    _extract_id \
    _upload_file \
    _generate_upload_link \
    _upload_file_from_uri \
    _normal_logging_upload \
    _log_upload_session \
    _remove_upload_session \
    _full_upload \
    _share_id
