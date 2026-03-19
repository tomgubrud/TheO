#!/bin/bash


set_variable () {
   red="tput setaf 1"
   green="tput setaf 2"
   yellow="tput setaf 3"
   blue="tput setaf 4"
   cyan="tput setaf 6"
   norm="tput setaf 9"
   who=snapadm
   sshrsakey=/Storage_Scripts/svc_scripts/data/ssh/snapadm
   # who=tpcaccess
   # sshrsakey=/Storage_Scripts/svc_scripts/data/ssh/id_rsa
   latest=/Storage_Scripts/svc_scripts/snapshot/output/latest
   in=/Storage_Scripts/svc_scripts/snapshot/input
   out=/Storage_Scripts/svc_scripts/snapshot/output
   scripts=/Storage_Scripts/svc_scripts/snapshot
   temp=/Storage_Scripts/svc_scripts/snapshot/tmp
   logs=/Storage_Scripts/svc_scripts/snapshot/logs
   ca_pure_x1=ca-pure-x-clstr1
   ca_pure_x2=ca-pure-x-clstr2
   ca_pure_c3=ca-pure-c-clstr3
   nj_pure_x1=nj-pure-x-clstr1
   nj_pure_x2=nj-pure-x-clstr2
   nj_pure_x3=nj-pure-x-clstr3
   ca_fs7300_1=ca_fs7300_clstr1
   ca_fs7300_2=ca_fs7300_clstr2
   nj_fs7300_1=nj_fs7300_clstr1
   nj_fs7300_2=nj_fs7300_clstr2
   dom=.newellrubbermaid.com
   today=`date +%Y%m%d-%H%M`
   mst_storage_team=f7b260e1.Newellco.onmicrosoft.com@amer.teams.ms     ## MS Teams Channel:  Storage Teams Channel
   mst_storage=5697f14e.Newellco.onmicrosoft.com@amer.teams.ms          ## MS Teams Channel:  Disaster Recovery Team - Storage-DR
   mst_unix=a9060c30.Newellco.onmicrosoft.com@amer.teams.ms             ## MS Teams Channel:  Disaster Recovery Team - Unix-DR
   mst_virt=0705332c.Newellco.onmicrosoft.com@amer.teams.ms             ## MS Teams Channel:  Disaster Recovery Team - Virtual-DR
   mst_dr=226bf207.Newellco.onmicrosoft.com@amer.teams.ms               ## MS Teams Channel:  Disaster Recovery Team - General-DR
   mst_dr_remediation=74d86fee.Newellco.onmicrosoft.com@amer.teams.ms   ## MS Teams Channel:  Disaster Recovery Team - Remediation
   mail_storage=gbl-dl-storageteam@newellco.com
   mail_dba=GBLDLDBAOracle@newellco.com
}


get_storageinfo () {
   # Gather files from Storage arrays
   echo "get_storageinfo function"
   while read array
      do
         $yellow; echo Gathering information on `$cyan` $array `$yellow` ..... `$norm`
         if [[ $array == *"pure"* ]]; then
            ssh -ni $sshrsakey $who@$array$dom purepod replica-link list > $out/$array.podreplicalist
            ssh -ni $sshrsakey $who@$array$dom purepgroup list> $out/$array.pglist
            ssh -ni $sshrsakey $who@$array$dom purevol list > $out/$array.vol
         else
            ssh -ni $sshrsakey $who@$array$dom lsvdisk -nohdr> $out/$array.lsvdisk
            ssh -ni $sshrsakey $who@$array$dom lsfcconsistgrp -nohdr> $out/$array.lsfcconsistgrp
            ssh -ni $sshrsakey $who@$array$dom lsfcmap -nohdr> $out/$array.lsfcmap
            ssh -ni $sshrsakey $who@$array$dom lshostvdiskmap > $out/$array.lshostvdiskmap
         fi
   done < $in/arrays
}


find_storagevolumeinfo () {
   # Using the VM, DS, and VOLID information from vcenter, find storage array and volume information
   echo "find_storagevolumeinfo function" $vm
   while read vm ds id
      do
         volarray=""
         volume=""

         # Try Pure data first
         for f in $out/*.vol; do
            [ -e "$f" ] || continue
            if grep -qi "$id" "$f"; then
               volarray=$(basename "${f%.vol}")
               volume=$(awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ id {print $1; exit}' "$f")
               break
            fi
         done

         # IBM mapping via host->vdisk map (vdisk_UID matches VM disk ID)
         if [ -z "$volume" ]; then
            for f in $out/*.lshostvdiskmap; do
               [ -e "$f" ] || continue
               if grep -qi "$id" "$f"; then
                  volarray=$(basename "${f%.lshostvdiskmap}")
                  volume=$(awk -v id="$id" '
                     BEGIN{IGNORECASE=1}
                     {
                        for (i=1; i<=NF; i++) {
                           if (tolower($i) == tolower(id) && i>1) {
                              print $(i-1)
                              exit
                           }
                        }
                     }' "$f")
                  break
               fi
            done
         fi

         # Fallback to lsvdisk if the ID appears there
         if [ -z "$volume" ]; then
            for f in $out/*.lsvdisk; do
               [ -e "$f" ] || continue
               if grep -qi "$id" "$f"; then
                  volarray=$(basename "${f%.lsvdisk}")
                  volume=$(awk -v id="$id" 'BEGIN{IGNORECASE=1} $0 ~ id {print $2; exit}' "$f")
                  break
               fi
            done
         fi

         if [ -z "$volarray" ] || [ -z "$volume" ]; then
            $red; echo "Unable to map VM $vm datastore $ds ID $id to storage volume"; $norm
            continue
         fi

         echo $volarray $volume >> $out/pure.snapinput

      done < $temp/volumes
}


execute_snap () {
   # Take snapshot
   rm $out/snaps 2> /dev/null

##   Input file:  /Storage_Scripts/svc_scripts/snapshot/input/vols
##   format MUST be:  Column 1:  full array name " " Column 2:  full volume name  (if pure, must include full name including protection group if any)
##   ex:  ca-pure-x-clstr1 DC1-N-823-Pure-X1

   while read array volume
      do
         $yellow; echo  Taking snapshot on volume: `$cyan` $volume `$yellow` on array `$cyan` $array `$yellow` ... `$norm`
         if [[ $array == *"pure"* ]]; then
            ssh -n -i $sshrsakey $who@$array$dom purevol snap --suffix snap-$today$suffix $volume >>/dev/null
            ssh -n -i $sshrsakey $who@$array$dom purevol list --snap $volume >> $out/snaps
         else
            if [[ $array == *"fs7300"* ]]; then
               diskinfo=$(ssh -n -i $sshrsakey $who@$array$dom svcinfo lsvdisk $volume)
               grainsize=$(echo "$diskinfo" |awk '$1=="grainsize"||$1=="grain_size"{print $2; exit}')
               iogrp=$(echo "$diskinfo" |awk '$1=="IO_group_name"{print $2; exit}')
               mdiskgrp=$(echo "$diskinfo" |awk '$1=="mdisk_grp_name"{print $2; exit}')
               prefnode=$(echo "$diskinfo" |awk '$1=="preferred_node_name"{print $2; exit}')
               raw_capacity=$(echo "$diskinfo" |awk '$1=="capacity"{print $2; exit}')
               unit="b"
               size_bytes=$(echo "$raw_capacity" | awk '
                  {
                     s=$0
                     gsub(/,/, "", s)
                     if (match(s, /^([0-9]+(\.[0-9]+)?)([[:alpha:]]*)$/, a)) {
                        num=a[1]; unit=tolower(a[3])
                        if (unit=="") unit="b"
                        if (unit=="b")  mult=1
                        else if (unit=="kb") mult=1024
                        else if (unit=="mb") mult=1024^2
                        else if (unit=="gb") mult=1024^3
                        else if (unit=="tb") mult=1024^4
                        else if (unit=="pb") mult=1024^5
                        else exit 2
                        printf "%.0f", num*mult
                        exit 0
                     }
                     exit 1
                  }')
               if [[ $? -ne 0 ]]; then
                  $red; echo "Unrecognized capacity '$raw_capacity' for $volume on $array; skipping snapshot"; $norm
                  continue
               fi

               if [[ -z "$grainsize" || -z "$iogrp" || -z "$mdiskgrp" || -z "$prefnode" || -z "$size_bytes" ]]; then
                  $red; echo "Missing volume metadata for $volume on $array; skipping snapshot"; $norm
                  continue
               fi

               ssh -n -i $sshrsakey $who@$array$dom svctask mkvdisk -autoexpand -grainsize $grainsize -iogrp $iogrp -mdiskgrp $mdiskgrp -name $volume"_"$today$suffix -node $prefnode -rsize 0% -size $size_bytes -unit b
               ssh -n -i $sshrsakey $who@$array$dom svctask mkfcmap -cleanrate 100 -copyrate 100 -source $volume -target $volume"_"$today$suffix -name $volume"_"$today$suffix
               ssh -n -i $sshrsakey $who@$array$dom svctask startfcmap -prep $volume"_"$today$suffix
               ssh -n -i $sshrsakey $who@$array$dom svcinfo lsfcmap -delim , -filtervalue source_vdisk_name=$volume |cut -d, -f2,4,17 >> $out/snaps
            else
              $red; echo Input file does not contain array names containing 'pure' or 'fs7300'; $norm
            fi
         fi
      #done < $in/vols
      done < $out/pure.snapinput
   $green; echo "Below is a list of all snapshots available on the in-scope volumes:"; $norm
   cat $out/snaps
}


send_notification () {
   mail -s "Adhoc Storage Snapshot information" $mail_storage $mail_dba < $out/snaps
#   mail -s "Adhoc Storage Snapshot information" $mail_storage < $out/snaps
#   mail -s "Adhoc Storage Snapshot information" thomas.gubrud@newellco.com < $out/snaps
#   mail -s "Adhoc Storage Snapshot information" thomas.gubrud@newellco.com < $logs/$logfile
}


get_datastoreinfo() {
   # Run powershell script to gather the datastore information (disk name and ID) for the VM passed into the program
    pwsh $scripts/get-ds-info.ps
    # Creates output file 'volumes' with vm name, datastore name, and volume uuid without double quotes, naa., or commas
    cat $temp/vm.csv |egrep -vi "Canonical|dc1_n_|dc2_n_" |sed 's/"//g' |sed 's/naa.//g' |sed 's/,/ /g' > $temp/v
    while read ds id; do echo $vm $ds ${id:8:24} >> $temp/volumes; done <$temp/v
##    cat $temp/volumes
#    while read ds; do echo $vm,$ds |sed 's/"//g' |sed 's/naa.//g' |sed 's/,/ /g' >> $temp/v; done < $in/vm.csv
#    while read vm ds id; do echo "VM is: " $vm, "Datastore is: " $ds, "Disk ID is: " $id |. && grep $id $out/.; done < $temp/volumes
}


cleanup () {
   rm $out/*
   rm $temp/*
}


ask_yes_or_no () {
   while true; do
      read -p "$1 (y)es, (n)o, (q)uit ?" yn
      case $(echo $yn | tr '[A-Z]' '[a-z]') in
        y|yes) echo "yes"; break;;
        n|no ) echo "no"; break;;
        q|quit ) exit 0;;
        * ) ;;
      esac
   done
   }


############################################################
############################################################
#
##  Checks for input paramter for snapshot suffix, if not provided sets requests user input
# Verify user wants to take a snapshot on specific server(s)
###if [ "no" == $(ask_yes_or_no "Do you want to run a storagea snapshot on specific VM(s) ? ") ]
###   then
###      $red; echo "Good-bye then........ " ;$norm
###      exit 0
###   else
###      echo "List of VMs a snapshot will be taken on:  "
###      cat $input/hosts
###fi
### while read -p "Enter name of VM (one at a time) to take snapshot on or Q when done and then Enter:  "  && [[ $REPLY != q ]]; do
###   echo $REPLY > $input/hosts
###
###if [ "no" == $(ask_yes_or_no "Enter suffix to append to snapshot name (up to 10 characters)  ? ") ]
###   then
###      $red; echo "Good-bye then........ " ;$norm
###      exit 0
###fi

#  if [ -z $1 ]
#  then
#    echo "Enter snapshot vm name to take snapshot on:  "
#    read vm
#    ##echo nothing passed, no suffix applied
#  else
#    vm=$1
#fi


# Main

# Logfile for the script execution.
#logfile=${logs}/${today}.log
#logfile=$logs/$today.log

# Point all the output to logfile also output them to the standard out.
#echo $logfile
#exec > >(tee -a ${logfile}) 2>&1


if test $# -eq 0; then
   #echo "Enter snapshot vm name to take snapshot on:  "
   #read vm
   echo No VM name passed to program, exiting...............Good Bye!
   exit 0
  else
      set_variable
      cleanup
      suffix=-$1
      echo $suffix
      shift
      echo Performing discovery on $# VMs......
      for vm; do
         echo $vm >> $temp/vminput
      done
      cat $temp/vminput
      get_datastoreinfo
      get_storageinfo
      find_storagevolumeinfo
      execute_snap
      send_notification

fi

## Revert back the logging to stdout
#exec 2>&1

#get_datastoreinfo
#get_storageinfo
#find_storagevolumeinfo
#gather_all_vols_info
# pure_info
#cleanup
#
############################################################
