#!/bin/ash

source "/config/icloudpd.conf"

# Check download health - monitor for filesystem activity
check_download_health()
{
   local current_time last_activity_time time_diff download_health_timeout_val
   
   # Get the configured timeout value, default to 7200 seconds (2 hours) if not set
   download_health_timeout_val="${download_health_timeout:-7200}"
   
   # Skip health check if disabled (timeout set to 0)
   if [ "${download_health_timeout_val}" -eq 0 ]
   then
      return 0
   fi
   
   current_time="$(date +%s)"
   
   # Look for download activity timestamps
   if [ -f "/tmp/icloudpd/last_download_activity" ]
   then
      last_activity_time="$(cat /tmp/icloudpd/last_download_activity 2>/dev/null || echo 0)"
   else
      # If no timestamp file exists, check if there's any download activity in the current log
      if [ -f "/tmp/icloudpd/icloudpd_sync.log" ]
      then
         # Check if there are any "Downloaded /" entries, indicating recent activity
         if grep -q "Downloaded /" /tmp/icloudpd/icloudpd_sync.log 2>/dev/null
         then
            # Update the timestamp and continue
            echo "${current_time}" > /tmp/icloudpd/last_download_activity
            return 0
         fi
      fi
      
      # No activity file and no recent downloads - create initial timestamp
      echo "${current_time}" > /tmp/icloudpd/last_download_activity
      return 0
   fi
   
   # Calculate time difference
   time_diff="$((current_time - last_activity_time))"
   
   # Check if we've exceeded the timeout
   if [ "${time_diff}" -gt "${download_health_timeout_val}" ]
   then
      # Check if container is supposed to be actively downloading
      # Look for signs that a sync process should be running but is stuck
      if [ -f "/tmp/icloudpd/icloudpd_sync.log" ]
      then
         # If log file exists but no recent downloads and timeout exceeded
         echo "Download health check failed: No filesystem activity for ${time_diff} seconds (timeout: ${download_health_timeout_val}s)"
         exit 2
      fi
   fi
   
   return 0
}

if [ -f "/tmp/icloudpd/icloudpd_check_exit_code" ] || [ -f "/tmp/icloudpd/icloudpd_download_exit_code" ]
then
   if [ -f "/tmp/icloudpd/icloudpd_download_exit_code" ]
   then
      download_exit_code="$(cat /tmp/icloudpd/icloudpd_download_exit_code)"
      # If the value is empty, set to 0 to presume healthy. Container is likely un-initialised and waiting for user input.
      # This prevents the healthcheck from restarting the container when combined with autoheal. 
      if [ "${download_exit_code:=0}" -ne 0 ]
      then
         echo "File download error: ${download_exit_code}"
         exit "${download_exit_code}"
      fi
   fi
   if [ -f "/tmp/icloudpd/icloudpd_check_exit_code" ]
   then
      check_exit_code="$(cat /tmp/icloudpd/icloudpd_check_exit_code)"
      # Same as before
      if [ "${check_exit_code:=0}" -ne 0 ]
      then
         echo "File check error: ${check_exit_code}"
         exit "${check_exit_code}"
      fi
   fi
else
   echo "Error check files missing."
   exit 1
fi

if [ -s "/tmp/icloudpd/icloudpd_check_error" ] || [ -s "/tmp/icloudpd/icloudpd_download_error" ]
then
   if [ -f "/tmp/icloudpd/icloudpd_check_error" ]
   then
      echo "Errors reported during file check"
      exit 1
   fi
   if [ -s "/tmp/icloudpd/icloudpd_download_error" ]
   then
      echo "Errors reported during file download"
      exit 1
   fi
fi

# Run download health check
check_download_health

cookie="$(echo -n "${apple_id//[^a-zA-Z0-9_]}" | tr '[:upper:]' '[:lower:]')"
if [ ! -f "/config/${cookie}" ]
then
	echo "Error: Cookie does not exist. Please generate new cookie"
	exit 1
fi

if [ "${authentication_type:=MFA}" = "MFA" ]
then
   mfa_expire_date="$(grep "X-APPLE-DS-WEB-SESSION-TOKEN" "/config/${cookie}" | sed -e 's#.*expires="\(.*\)Z"; HttpOnly.*#\1#')"
   mfa_expire_seconds="$(date -d "${mfa_expire_date}" '+%s')"
   days_remaining="$(($((mfa_expire_seconds - $(date '+%s'))) / 86400))"
   if [ -z "${notification_days}" ]
   then
      notification_days=7
   fi
   if [ "${days_remaining}" -le "${notification_days}" ] && [ "${days_remaining}" -ge 1 ]
   then
      echo "Warning: Multi-factor authentication cookie is due for renewal in ${notification_days} days"
   elif [ "${days_remaining}" -lt 1 ]
   then
      echo "Error: Multi-factor authentication cookie has expired"
      exit 1
   fi
elif [ "${authentication_type}" = "Web" ]
then
   web_cookie_expire_date="$(grep "X_APPLE_WEB_KB" "/config/${cookie}" | sed -e 's#.*expires="\(.*\)Z"; HttpOnly.*#\1#')"
   web_cookie_expire_seconds="$(date -d "${web_cookie_expire_date}" '+%s')"
   days_remaining="$(($((web_cookie_expire_seconds - $(date '+%s'))) / 86400))"
else
   echo "Error: Authentication type not recognised"
   exit 1
fi

echo "iCloud Photos Downloader successful and ${authentication_type} cookie valid for ${days_remaining} day(s)"

exit 0