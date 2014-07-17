#!/bin/sh

# git_inetd_server.sh -- Serve Git http protocol via inetd
# Copyright (C) 2014 Kyle J. McKay.  All rights reserved.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/gpl-2.0>.

# Version 1.0

# This script should be configured as an inetd nowait
# service on any desired port.
#
# The following environment variables MUST be set when
# it's called:
#     GIT_HTTP_BACKEND_BIN -- absolute path to git-http-backend
#     GIT_PROJECT_ROOT     -- absolute path to projects root dir
#
# A suitable GIT_HTTP_BACKEND_BIN value can usually be found with:
#     echo $(git --exec-path)/git-http-backend
#
# Note that only GET and POST requests are allowed.
#
# Note that pushes are only enabled by default if REMOTE_USER is
# set and this script leaves REMOTE_USER untouched so beware if something
# else sets that before running this script as that will enable pushing
# unless there's an explicit http.receivepack setting set to false!
# In any case explicitly setting http.receivepack to true will enable pushing
# regardless of the REMOTE_USER setting.  Since this script does not provide
# any kind of authentication services you probably do not want that.
#
# To disallow non-smart HTTP access set http.getanyfile to false either in each
# repository or in the global or system config file.
#
# The output from git-http-backend will be gzip encoded automatically if the
# gzip encoding appears in Accept-Encoding and the git-http-backend output is
# not already gzip encoded.  The compression level used is only 1 to keep the
# server burden as small as possible.
#
# A sample inetd config line might look like this:
#   githttp stream tcp nowait gituser /path/to/git_inetd_server git_inetd_server
#
# Although in practice the /path/to/git_inetd_server may need to be replaced
# with /usr/bin/env in order to set the GIT_HTTP_BACKEND_BIN and GIT_PROJECT_DIR
# environment variables properly before invoking this script.  An entry in
# /etc/services may also need to be added for githttp as well like so:
#   githttp 8418/tcp # git http pack transfer service
#
# where 8418 is replaced with the appropriate port number.  Using xinetd
# instead of inetd avoids needing to modify /etc/services to get a custom port.

errorhdrs()
{
	printf '%s\r\n' "HTTP/1.0 $1 $2"
	printf '%s\r\n' "Connection: close"
	printf '%s\r\n' "Expires: Fri, 01 Jan 1980 00:00:00 GMT"
	printf '%s\r\n' "Pragma: no-cache"
	printf '%s\r\n' "Cache-Control: no-cache, max-age=0, must-revalidate"
	printf '%s\r\n' "Content-Type: text/plain"
	printf '\r\n'
}

msglines()
{
	while [ $# -gt 0 ]; do
		printf '%s\n' "$1"
		shift
	done
}

clienterr()
{
	errorhdrs "$1" "$2"
	msglines "$2"
	exit 0
}

servererr()
{
	errorhdrs "${1:-500}" "${2:-Internal Server Error}"
	msglines "${2:-Internal Server Error}"
	msglines "${2:-Internal Server Error}" >&2
	exit 0
}

[ -n "$GIT_HTTP_BACKEND_BIN" -a -n "$GIT_PROJECT_ROOT" ] || servererr
[ -x "$GIT_HTTP_BACKEND_BIN" ] || servererr
[ -d "$GIT_PROJECT_ROOT" ] || servererr

read -r method uri proto
uri="$(printf '%s' "$uri" | tr -d '\r')"
proto="$(printf '%s' "$proto" | tr -d '\r')"
[ -z "$proto" ] || export SERVER_PROTOCOL="$proto"

if [ "$method" != "GET" ] && [ "$method" != "POST" ]; then
	clienterr 405 "Method Not Allowed"
fi

valid=
while read -r header; do
	header="$(printf '%s' "$header" | tr -d '\r')"
	if [ -z "$header" ]; then
		valid=1
		break
	fi
	case "$header" in
		[Aa][Cc][Cc][Ee][Pp][Tt]:*)
			header="${header#*:}"
			export HTTP_ACCEPT="${header# }"
			;;
		[Aa][Cc][Cc][Ee][Pp][Tt]-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:*)
			header="${header#*:}"
			export HTTP_ACCEPT_ENCODING="${header# }"
			;;
		[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:*)
			header="${header#*:}"
			export HTTP_CONTENT_ENCODING="${header# }"
			;;
		[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Th][Hh]:*)
			header="${header#*:}"
			export CONTENT_LENGTH="${header# }"
			;;
		[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Tt][Yy][Pp][Ee]:*)
			header="${header#*:}"
			export CONTENT_TYPE="${header# }"
			;;
		[Uu][Ss][Ee][Rr]-[Aa][Gg][Ee][Nn][Tt]:*)
			header="${header#*:}"
			export HTTP_USER_AGENT="${header# }"
			;;
	esac
done
[ -n "$valid" ] || clienterr 400 "Bad Request"

case "$uri" in /*) :;; *)
	clienterr 400 "Bad Request"
esac

shouldgzip=
case "$HTTP_ACCEPT_ENCODING" in *gzip*)
	shouldgzip=1
esac

export REQUEST_METHOD="$method"
export PATH_INFO="${uri%%[?]*}"
QUERY_STRING="${uri#$PATH_INFO}"
export QUERY_STRING="${QUERY_STRING#[?]}"

{ "$GIT_HTTP_BACKEND_BIN" || servererr; } | \
{
	valid=
	headers=
	code=
	message=
	status=
	hasencoding=
	while read -r header; do
		header="$(printf '%s' "$header" | tr -d '\r')"
		if [ -z "$header" ]; then
			valid=1
			break
		fi
		case "$header" in
		"Status:"*)
			status=1
			header="${header#Status:}"
			header="${header# }"
			code="${header%%[!0-9]*}"
			header="${header#$code}"
			message="${header# }"
			header=
			;;
		[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ee][Nn][Cc][Oo][Dd][Ii][Nn][Gg]:*)
			hasencoding=1
			;;
		esac
		if [ -n "$header" ]; then
			headers="$headers$(printf '%s\r\n.' "$header")"
			headers="${headers%.}"
		fi
	done
	[ -n "$valid" ] || servererr
	if [ -z "$status" ]; then
		code=200
		message="OK"
	fi
	case "$code" in
		2[0-9][0-9])
			:
			;;
		[4][0-9][0-9])
			clienterr "$code" "${message:-$code error}"
			;;
		[5][0-9][0-9])
			servererr "$code" "${message:-$code error}"
			;;
		*)
			servererr
			;;
	esac
	printf '%s\r\n' "HTTP/1.0 $code ${message:-OK}"
	printf '%s\r\n' "Connection: close"
	printf '%s' "$headers"
	if [ -z "$hasencoding" -a -n "$shouldgzip" ]; then
		printf '%s\r\n' "Content-Encoding: gzip" ""
		exec gzip -1
	else
		printf '%s\r\n' ""
		exec cat
	fi
}
