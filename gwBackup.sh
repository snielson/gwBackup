#!/bin/bash
##################################################################################################
#																								
#	gwBackup.sh
#	by Tyler Harris and Shane Nielson
#
##################################################################################################
# TODO: Fix cron thinking $PWD is /root
##################################################################################################
#
#	gwBackup Configuration
#
##################################################################################################
	conf="/etc/gwBackup.conf"

	# Create gwBackup.conf at current script location.
	if [ ! -f "$conf" ];then
		echo -e '#Configuration Settings\nlog="/var/log/gwBackup.log"\ndebug=false\nsource=""\ndest=""\nstartHour=22\nnumOfWeeks=3\nstartDay=\ndbCopyUtil="/opt/novell/groupwise/agents/bin/dbcopy"\n\nisDestMounted=false\nconfigured=false\n\n#Backup script tracking\nbackupRoutine=false\ncurrentWeek=0\ncurrentDay=1\n' > "$conf"
	fi

##################################################################################################
#
#	Declare Variables
#
##################################################################################################

	nextWeek=false;
	sourceSize=0
	destSize=0
	cronFile="/etc/cron.d/gwBackup"
	source "$conf"

##################################################################################################
#
#	Logger
#
##################################################################################################
	
	if [[ "${INTERACTIVE_MODE}" == "off" ]]
	then
	    # Then we don't care about log colors
	    declare -r LOG_DEFAULT_COLOR=""
	    declare -r LOG_ERROR_COLOR=""
	    declare -r LOG_INFO_COLOR=""
	    declare -r LOG_SUCCESS_COLOR=""
	    declare -r LOG_WARN_COLOR=""
	    declare -r LOG_DEBUG_COLOR=""
	else
	    declare -r LOG_DEFAULT_COLOR="\e[0m"
	    declare -r LOG_ERROR_COLOR="\e[31m"
	    declare -r LOG_INFO_COLOR="\e[0m"
	    declare -r LOG_SUCCESS_COLOR="\e[32m"
	    declare -r LOG_WARN_COLOR="\e[33m"
	    declare -r LOG_DEBUG_COLOR="\e[34m"
	fi

	# This function scrubs the output of any control characters used in colorized output
	# It's designed to be piped through with text that needs scrubbing.  The scrubbed
	# text will come out the other side!
	prepare_log_for_nonterminal() {
	    # Essentially this strips all the control characters for log colors
	    sed "s/[[:cntrl:]]\[[0-9;]*m//g"
	}

	log() {
	    local log_text="$1"
	    local log_level="$2"
	    local log_color="$3"

	    # Default level to "info"
	    [[ -z ${log_level} ]] && log_level="INFO";
	    [[ -z ${log_color} ]] && log_color="${LOG_INFO_COLOR}";

	    echo -e "${log_color}[$(date +"%Y-%m-%d %H:%M:%S %Z")] [${log_level}] ${log_text} ${LOG_DEFAULT_COLOR}" >> "$log";
	    return 0;
	}

	log_info()      { log "$@"; }
	log_success()   { log "$1" "SUCCESS" "${LOG_SUCCESS_COLOR}"; }
	log_error()     { log "$1" "ERROR" "${LOG_ERROR_COLOR}"; }
	log_warning()   { log "$1" "WARNING" "${LOG_WARN_COLOR}"; }
	log_debug()     { if ($debug); then log "$1" "DEBUG" "${LOG_DEBUG_COLOR}"; fi }

##################################################################################################
#
#	Functions
#
##################################################################################################
	# Utility
		function askYesOrNo {
			REPLY=""
			while [ -z "$REPLY" ] ; do
				read -ep "$1 $YES_NO_PROMPT" REPLY
				REPLY=$(echo ${REPLY}|tr [:lower:] [:upper:])
				log "[askYesOrNo] : $1 $REPLY"
				case $REPLY in
					$YES_CAPS ) return 0 ;;
					$NO_CAPS ) return 1 ;;
					* ) REPLY=""
				esac
			done
		}

		# Initialize the yes/no prompt
		YES_STRING=$"y"
		NO_STRING=$"n"
		YES_NO_PROMPT=$"[y/n]: "
		YES_CAPS=$(echo ${YES_STRING}|tr [:lower:] [:upper:])
		NO_CAPS=$(echo ${NO_STRING}|tr [:lower:] [:upper:])

		function isPathMounted {
			# If directory is different than /root, then we presume the path 
			# is mounted and we should verify the mount in the future
			if [ `stat -fc%t:%T "$1"` != `stat -fc%t:%T "/"` ]; then
			    return 0
			else
			    return 1
			fi
		}

		function promptVerifyPath {
			while [ true ];do
	    		read -ep "$1" path;
		        if [ ! -d "$path" ]; then
		            if askYesOrNo $"Path does not exist, would you like to create it now?"; then
		                mkdir -p $path;
		                break;
		            fi
		        else break;
		        fi
		    done
		    eval "$2='$path'"
		}

		function promptVerifyFile {
			while [ true ];do
	    		read -ep "$1" file;
		        if [ -f "$file" ]; then
		            break
		        else echo -e "File not found!\n"
		        fi
		    done
		    eval "$2='$file'"
		}

		function pushConf {
			local header="[pushConf] [$conf] :"
			# $1 = variableName | $2 = value
			sed -i "s|$1=.*|$1=$2|g" "$conf";
			if [ $? -eq 0 ];then
				log_debug "$header $1 has been reconfigured to $2"
			else
				log_error "$header Failed to reconfigure $1 to $2"
			fi
		}

		function pushArrayConf {
			# $1 = array value | $2 = new array value
			local lineNumber=`grep weekArray= -n $conf | cut -d ':' -f1`
			sed -i ""$lineNumber"s|'$1'|'$2'|g" "$conf";
		}

		function checkDBCopy {
			if [ ! -f "$dbCopyUtil" ]; then
				# Couldn't find dbcopy in default install location
				promptVerifyFile "Path to DBCopy? " dbCopyUtil
				pushConf "dbCopyUtil" "\"$dbCopyUtil\""
			fi
		}

		function dsappLogRotate {
			logRotate="$(cat <<EOF                                                        
$log {
    compress
    compresscmd /usr/bin/gzip
    dateext
    maxage 14
    rotate 99
    missingok
    notifempty
    size +4096k
    create 640 root root
}                                     
EOF
			)"
			if [ ! -f "/etc/logrotate.d/gwBackup" ];then
				log_info "[Init] [logRotate] Creating /etc/logrotate.d/gwBackup"
				echo -e "$logRotate" > /etc/logrotate.d/gwBackup
			fi
		}

		function calcSourceSize { # $1 = Output back to variable
			local size=0;
			local size2=0;

			isPathGW "$source"
			if [ $? -eq 0 ];then
				size=`du -sh $source`
			elif [ $? -eq 1 ];then
				size=`du -s $source --exclude='offiles' | awk '{print $1}'`
				size2=`du -s $source/offiles | awk '{print $1}'`
				size=$(($size * $numOfWeeks))
				size=$(($size * 7))
				size=$(($size + $size2))
			else
				size="Unknown source"
			fi
			eval "$1=$size"
		}

		function isPathGW {
			local header="[isPathGW] :"
			if [ -f "$1/wpdomain.db" ];then
				log_info "$header Path verified as domain (wpdomain.db): $1"
				return 0
			elif [ -f "$1/wphost.db" ];then
				log_info "$header Path verified as po (wphost.db): $1"
				return 1
			else
				log_error "$header Path doesn't contain wpdomain.db or wphost.db: $1"
				return 3
			fi
		}

		function calcDestSize { # $1 = path to check | $2 = Output back to variable
			local size=`df "$1" | grep -vE '^udev|_admin|tmpfs|cdrom|Filesystem' | awk '{ print $3}'`
			eval "$2=$size"
		}

		function diskPercentUsed { 
			# $1 = path to check | $2 = Output back to variable
			local size=$(df $1 | grep -vE '^udev|_admin|tmpfs|cdrom|Filesystem' | awk '{ print $5}' | cut -d'%' -f1)
			eval "$2=$size"
		}

		function storagePercentCheck {
			sizePercentWanring=0
			diskPercentUsed "$1" sizePercentWanring
			if [ $sizePercentWanring -ge 90 ]; then
				log_warning "Destination $1 low on disk space."
				sizePercentWanring=`echo $(date)" Destination $1 low on disk space."`
			else sizePercentWanring=""
			fi
		}

		function storageSizeCheck { # Requires calcSourceSize & calcDestSize be called to compare
			calcSourceSize sourceSize;
			calcDestSize "$dest" destSize;
			if [ "$destSize" -lt "$sourceSize" ];then
				log_error "Destination $dest has insufficient storage space."
				sizeWarning=`echo $(date)" Destination $dest has insufficient storage space."`
			else sizeWarning=""
			fi
		}

		function confArray {
			arrayValue="'0'"
				for (( count=1; count<$numOfWeeks; count++));
				do
					arrayValue=`echo $arrayValue "'$count'"` 
				done
		}

		# Init-Configure
			# Prompt for input: source/dest, maxWeeks
			function configure {
				clear; echo -e "###################################################\n#\n#	Confiruging gwBackup\n#\n###################################################\n"
				
				while true
				do
					promptVerifyPath "Path to [DOM|PO] Directory: " source
					isPathGW "$source"
					if [ $? -ne 3 ]; then 
						pushConf "source" "\"$source\""
						break
					else
						echo -e "Path doesn't contain wphost.db or wpdomain.db - not a GW Path!\n"
					fi
				done

				promptVerifyPath "Destination path: " dest
				pushConf "dest" "\"$dest\""
				isPathMounted "$dest"
				if [ $? -eq 0 ]; then 
					pushConf "isDestMounted" true
				fi
				echo

				checkDBCopy

				# Get number of weeks for backups (Must be 3 or more)
				while true
				do
					local defaultnumOfWeeks=3
					read -ep "Number of weeks for backups [$numOfWeeks]: " numOfWeeks
						numOfWeeks="${numOfWeeks:-$defaultnumOfWeeks}"
					if [ "$numOfWeeks" -ge '3' ];then
						pushConf "numOfWeeks" $numOfWeeks
						break;
					else
						echo "3 or more required."
						numOfWeeks=$defaultnumOfWeeks;
					fi
				done

				# Create empty array into gwback.conf
				confArray;
				echo -e "\n#gwBackup week array\nweekArray=( $arrayValue )" >> "$conf"

				# Check required storage space on dest
				storageSizeCheck
				if [ -n "$sizeWarning" ];then
					echo $sizeWarning;
					rm $conf;
					exit 1;
				fi

				cleanCron;
				configureCronJob;
				dsappLogRotate;

				pushConf "configured" true
				exit 0;
			}

			function configureCronJob {
				configureStartHour
				configureStartDay
				local header="[configureCronJob]"
				local cronTask="0 $startHour * * * root $PWD/gwBackup.sh"

				if [ -f "$cronFile" ]; then
					sed -i "s|.*gwBackup.sh.*|$cronTask|g" "$cronFile"
				else
					echo "$cronTask" >> "$cronFile"
				fi

				log_info "$header : $cronTask"
			}

			function configureStartHour {
				while true 
				do
					read -p "Enter start hour (24-hour clock: 0..23); 0 is midnight: " startHour
					if [[ $startHour =~ ^[0-23]{1,2}$ ]]; then
						pushConf "startHour" $startHour
						break;
					else
						echo -e "Invalid hour format\n"
					fi
				done
			}

			function configureStartDay {
				echo -e "\nNote: gwBackup routines will be enabled on this day."
				while true 
				do
					read -p "Enter start day of week (0..6); 0 is Sunday: " startDay
					if [[ $startDay =~ ^[0-6]{1}$ ]]; then
						pushConf "startDay" $startDay
						break;
					else
						echo -e "Invalid day format\n"
					fi
				done
			}

			function cleanCron {
				local header="[cleanCron] :"

				if [ -f "$cronFile" ]; then
					log_info "$header Removing $cronFile"
					rm "$cronFile"
					if [ $? -eq 0 ];then
						log_info "$header Removing $cronFile"
					else
						log_error "$header Problem removing $cronFile"
					fi
				else
					log_warning "File doesn't exist: $cronFile"
				fi

			}

			function cleanConf {
				local header="[cleanConf] :"
				sed -i '/.*gwBackup week array.*/d' $conf
				sed -i '/.*weekArray=.*/d' $conf
				sed -i '$d' $conf

				pushConf "currentDay" 1;
				pushConf "currentWeek" 0;
				pushConf "backupRoutine" false
				log_info "$header gwBackup.conf has been reset to defaults"
			}

		# Backup routine functions
			function checkDay {
				local header="[checkDay]"

				function bumpDay {
					# Increases currentDay by 1
					currentDay=$(($currentDay + 1))
					if [ $? -eq 0 ];then
						pushConf "currentDay" "$currentDay";
						log_debug "$header [Set] [currentDay] : Set to $currentDay"
					else
						log_error "$header [Set] [currentDay] : Failed to set $currentDay"
					fi
				}
					
				if [[ "$currentDay" -ne '8' ]];then
					if [ ! -d "$dest/gwBackup/${weekArray[$currentWeek]}/day"$currentDay"" ];then
						mkdir -p $dest/gwBackup/${weekArray[$currentWeek]}/day"$currentDay"
						if [ $? -eq 0 ];then
							log_info "$header [${weekArray[$currentWeek]}/day$currentDay] : Day folder created."
						else
							log_error "$header [${weekArray[$currentWeek]}/day$currentDay] : Failed to create day folder."
						fi

						if [ "$currentDay" -ne '1' ] && [ "$currentDay" -ne '8' ];then
							# Create soft link to day1 offiles
							ln -s "../day1/offiles" $dest/gwBackup/${weekArray[$currentWeek]}/day"$currentDay";
							if [ $? -eq 0 ];then
								log_info "$header [${weekArray[$currentWeek]}/day$currentDay] : Offiles soft link created."
							else
								log_error "$header [${weekArray[$currentWeek]}/day$currentDay] : Failed to create soft link."
							fi
						fi

						# DBcopy source to dest/gwBackup
						log_info "[DBCopy] [${weekArray[$currentWeek]}/day$currentDay] : Running backup process."
						$dbCopyUtil $source $dest/gwBackup/${weekArray[$currentWeek]}/day"$currentDay" >> $log
						if [ $? -eq 0 ];then
							log_success "[DBCopy] [${weekArray[$currentWeek]}/day$currentDay] : Backup created."
						else
							log_error "[DBCopy] [${weekArray[$currentWeek]}/day$currentDay] : Backup failed."
						fi
						bumpDay;
					else
						log_error "$header [${weekArray[$currentWeek]}/day$currentDay] : Folder already exists."
					fi
				fi

			}

			function checkWeek {
				local header="[checkWeek]"
				# Assign variable $now to current date in seconds.
				now=$(date +"%m-%d-%Y")

				# Set currentDay back to 1 if new week
				if ($nextWeek);then
					currentDay=1;
					if [ $? -eq 0 ];then
						pushConf "currentDay" "$currentDay";
						log_debug "$header [Set] [currentDay] : Set to $currentDay"
					else
						log_error "$header [Set] [currentDay] : Failed to set $currentDay"
					fi
					nextWeek=false;
				fi

				# Create new week folder on currentDay 1 and not at the end of week
				if [[ "$currentWeek" -lt "$numOfWeeks" ]] && [[ "$currentDay" -eq '1' ]];then
					mkdir -p $dest/gwBackup/$now;
					if [ $? -eq 0 ];then
						log_info "$header [${weekArray[$currentWeek]}] : Week folder created."
						pushArrayConf "$currentWeek" "$now"
						pushArrayConf "${weekArray[$currentWeek]}" "$now"
						weekArray[$currentWeek]=$now;
						log_info "$header : Set weekArray index $currentWeek to $now"
					else
						log_error "$header [${weekArray[$currentWeek]}] : Failed to create week folder."
					fi

				# Jump to the next week, and delete any old folder (oldest) if folder exists
				elif  [[ "$currentWeek" -lt "$numOfWeeks" ]] && [[ "$currentDay" -eq '8' ]];then
					currentWeek=$(($currentWeek + 1))
					log_info "$header [currentWeek] : Set to $currentWeek"
					pushConf "currentWeek" "$currentWeek";
					if [ "$currentWeek" -ne "$numOfWeeks" ];then
						rm -rf $dest/gwBackup/${weekArray[$currentWeek]}
						if [ $? -eq 0 ];then
							log_info "$header [Maint] [${weekArray[$currentWeek]}] : Folder removed"
						else
							log_error "$header [Maint] [${weekArray[$currentWeek]}] : Failed to remove folder"
						fi
					fi
					nextWeek=true
					checkWeek;

				# At the end of the week limit cycle. Set weeks to start over.
				elif [[ "$currentWeek" -eq "$numOfWeeks" ]] && [[ "$currentDay" -eq '1' ]];then
					rm -rf $dest/gwBackup/${weekArray[0]}
					if [ $? -eq 0 ];then
						log_info "$header [Maint] [${weekArray[0]}] : Folder removed"
					else
						log_error "$header [Maint] [${weekArray[0]}] : Failed to remove folder"
					fi
					currentWeek=0;
					log_info "$header [Set] [currentWeek] : Set to $currentWeek"
					pushConf "currentWeek" "$currentWeek";
					nextWeek=true
					checkWeek;
				fi

			}


##################################################################################################
#
#	Switches
#
##################################################################################################

	gwBackupSwitch=0
	while [ "$1" != "" ]; do
		case $1 in #Start of Case

		--help | '?' | -h) gwBackupSwitch=1
			echo -e "gwBackup switches:";
			# echo -e "      \t--debug\t\tToggles gwBackup log debug level [$debug]"
			echo -e "     \t--debug\t\tTrigger debug $log [$debug]"
			echo -e "  -c \t--configure\tRe-Configure gwBackup"
			echo -e "  -cc \t--clearCron\tRemove $cronFile"
			echo -e "  -r \t--reset\t\tReset $conf to defaults"
		;;

		--configure | -c) gwBackupSwitch=1
			pushConf "configured" false
			if askYesOrNo $"Reset $conf to defaults?";then
				cleanConf;
			fi
			configure
		;;

		--debug ) gwBackupSwitch=1
			if [ "$debug" = "true" ];then
				pushConf "debug" false;
				echo "Setting $log debug: false"
			else
				pushConf "debug" true;
				echo "Setting $log debug: true"
			fi
		;;

		--reset | -r) gwBackupSwitch=1
			cleanConf;
		;;

		--cleanCron | -cc) gwBackupSwitch=1
			cleanCron;
			echo "Crontab has been cleaned of gwBackup.sh"
		;;

		# Not valid switch case
	 	*) 
	 	 ;; 
		esac # End of Case
		shift;
	done

	# Exits 0 if gwBackupSwitch = 1
	if [ "$gwBackupSwitch" -eq "1" ];then
	exit 0;
	fi

##################################################################################################
#
#	Startup / Initialization / User-Input Configuration
#
##################################################################################################
	# Initialize the yes/no prompt
		YES_STRING=$"y"
		NO_STRING=$"n"
		YES_NO_PROMPT=$"[y/n]: "
		YES_CAPS=$(echo ${YES_STRING}|tr [:lower:] [:upper:])
		NO_CAPS=$(echo ${NO_STRING}|tr [:lower:] [:upper:])

	# Configure gwBackup if not already configured
	if (! $configured); then
		configure
	else 
		# Checks
		storagePercentCheck "$dest"
	fi

	# If mounted. Verify it is still a mountpoint.
	if($isDestMounted);then
		isPathMounted "$dest"
		if [ $? -ne 0 ]; then 
			log_error "Destination $dest mountpoint failure."
			exit 1;
		fi
	fi

##################################################################################################
#
#	Weekly Backup Routine / Nightly Incremental Backup Routine
#
##################################################################################################
	
	# Only start the routine backup process on the day that is selected during configuration (one-time configuration)
	if (! $backupRoutine); then
		if [[ $startDay -eq $(date '+%w') ]]; then
			backupRoutine=true
			pushConf "backupRoutine" true
		fi
	fi

	if($backupRoutine);then
		log_info "Beginning backup routine: Source: $source | Dest: $dest"
		checkWeek;
		checkDay;
	fi

exit 0;