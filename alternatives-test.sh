#!/bin/bash

# $PREP_SCRIPT is script, which can be run to prepare tested product. Defaults to cleanAndInstallRpms
# $PURGE_SCRIPT is script, which can be run to uninstall all JDK from the systemíá

set -x
set +e
set -o pipefail

## assumes that both directories with old and new rpms are provided and filled with relevant rpms
## this script attempts parallel installation of old and new set of rpms

## resolve folder of this script, following all symlinks,
## http://stackoverflow.com/questions/59895/can-a-bash-script-tell-what-directory-its-stored-in
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  SCRIPT_DIR="$( cd -P "$( dirname "$SCRIPT_SOURCE" )" && pwd )"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
readonly SCRIPT_DIR="$( cd -P "$( dirname "$SCRIPT_SOURCE" )" && pwd )"

# ${PREP_SCRIPT} may be set by user. If not, lets use some default.
if [[ x${PREP_SCRIPT} == x ]]; then
  PREP_SCRIPT="/mnt/shared/TckScripts/jenkins/benchmarks/cleanAndInstallRpms.sh"
fi
# ${PREP_SCRIPT} may be set by user. If not, lets use some default.
if [[ x${PURGE_SCRIPT} == x ]]; then
  PURGE_SCRIPT="/mnt/shared/TckScripts/jenkins/benchmarks/uninstallRpms.sh"
fi
# setup workspace
if [[ -z "${WORKSPACE}" ]]; then
WORKSPACE=/mnt/workspace
fi
# ${TEST_RPM_DIR} should be set by user. If not, lets use some default.
if [[ -z "${TEST_RPM_DIR}" ]]; then
TEST_RPM_DIR=${WORKSPACE}/rpms
fi

PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
VER=$OTOOL_JDK_VERSION
MASTERS_JAVA="java"
MASTERS_JRE="jre_$VER jre_openjdk jre_${VER}_openjdk"
MASTERS_JAVAC="javac"
MASTERS_SDK="java_sdk_$VER java_sdk_openjdk java_sdk_${VER}_openjdk"
MASTERS_JAVADOC="javadocdir javadoczip"
MASTERS_ALL="${MASTERS_JRE} ${MASTERS_JAVA} ${MASTERS_SDK} ${MASTERS_JAVAC} ${MASTERS_JAVADOC}"
LOG_PATH="${WORKSPACE}/alternatives-test-logs"
rm -rf $LOG_PATH
mkdir $LOG_PATH
declare -A RESULTS_LOG
RPM_DOWNLOAD_DIR="${WORKSPACE}/rpms_all_jdks/"
mkdir $RPM_DOWNLOAD_DIR
SUITE="alternatives-test"

pushd $WORKSPACE
git clone https://github.com/rh-openjdk/run-folder-as-tests.git
source $WORKSPACE"/run-folder-as-tests/jtreg-shell-xml.sh"
# ---- prepare previous released rpms into a folder for update testing purposes
bash ${PREP_SCRIPT}
sudo dnf downgrade --downloadonly --downloaddir="${RPM_DOWNLOAD_DIR}" -y  java-11-openjdk-devel* java-11-openjdk-headless* java-11-openjdk-javadoc* java-17-openjdk-devel* java-17-openjdk-headless* java-17-openjdk-javadoc* java-1.8.0-openjdk-devel* java-1.8.0-openjdk-headless* java-1.8.0-openjdk-javadoc*
if [ $? -ne 0 ] ; then 
  SKIP_UPDATE=true
fi
bash ${PURGE_SCRIPT}

#-------------- Function to run on master, which returns 0 if master status is automatic, 1 it is manual
function isAutomatic() {
alternatives --display $1 | grep "status is auto" 
if [ $? -eq 0 ] ; then 
  echo "Status of $1 alternatives is automatic."
  return 0
else  
  echo "Status of $1 alternatives is manual."
  return 1
fi
}

#-------------- Install all rpms in rpm folder and check, that status is automatic after install
#TODO this could be maybe ran for all masters?, not just java&javac? and also fastdebug/slowdebug only?
bash ${PREP_SCRIPT}
popd

JDK_MASTERS_DEF="java javac"
for java_master in $JDK_MASTERS_DEF
 do
  LOGNAME=$java_master"_is_manual_after_clean_install.log"
  LOG_FILE=$LOG_PATH"/"$LOGNAME
  touch $LOG_FILE
  if isAutomatic $java_master ; then
    echo "PASS: Master $java_master is in automatic mode after fresh install." >> $LOGNAME
    RESULTS_LOG[$LOGNAME]=1
    continue
  else
    echo "FAIL: Master $java_master is in manual mode even if it should be automatic after fresh install. This can mean corrupted environment, broken install scripts, or broken rpm."  >> $LOGNAME
    RESULTS_LOG[$LOGNAME]=0
  fi
done
 
#-------------- Test that for tested jdk, release is selected by default on all masters after install
for masterX in $MASTERS_ALL 
 do
  LOGNAME=$masterX"_has_release_selected_by_default_after_install.log"
  LOG_FILE=$LOG_PATH"/"$LOGNAME
  touch $LOG_FILE
  alternatives --display ${masterX} >> $LOG_FILE 2>&1
  SELECTED_JDK=$( cat $LOG_FILE | grep "link currently points to" | awk '{print $NF}' )
  if [[ "fastdebug" == *$SELECTED_JDK* ]]; then
   echo "FAIL: Fastdebug jdk is selected by default for ${masterX} even though release is present. This is most likely a priority issue." >> $LOG_FILE
   RESULTS_LOG[$LOGNAME]=1
  elif [[ "slowdebug" == *$SELECTED_JDK* || "debug" == *$SELECTED_JDK* ]] ; then
   echo "FAIL: Slowdebug jdk is selected by default for ${masterX} even though release is present. This is most likely a priority issue." >> $LOG_FILE
   RESULTS_LOG[$LOGNAME]=1
  else
   echo "PASS: Release jdk is selected as expected." >> $LOG_FILE
   RESULTS_LOG[$LOGNAME]=0
  fi
done

#-------------- Test all expected masters exist against a hardcoded list of masters after install
for masterM in $MASTERS_ALL 
  do
    LOGNAME=$masterM"_exists_after_install.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    alternatives --display $masterM  >> $LOG_FILE 2>&1
    if [ $? -eq 0 ] ; then 
      RESULTS_LOG[$LOGNAME]=0
    else
      RESULTS_LOG[$LOGNAME]=1
    fi
  done

#-------------- Cleanup the environment and purge all JDK to prepare for next tests
sudo bash ${PURGE_SCRIPT}

#-------------- Install current released version of the tested packages and upgrade
sudo dnf install -y java-${VER}-openjdk-devel* java-${VER}-openjdk-headless* java-${VER}-openjdk-javadoc*
sudo dnf update -y ${TEST_RPM_DIR}/*

#-------------- Test that for tested jdk, release is selected by default on all masters after upgrade
for masterX in $MASTERS_ALL 
  do
    LOGNAME=$masterX"_has_release_selected_by_default_after_upgrade.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    alternatives --display ${masterX}  >> $LOG_FILE 2>&1
    SELECTED_JDK=$( cat $LOG_FILE | grep "link currently points to" | awk '{print $NF}' )
    if [[ "fastdebug" == *$SELECTED_JDK* ]]; then
     echo "FAIL: Fastdebug jdk is selected by default for ${masterX} even though release is present. This is most likely a priority issue." >> $LOG_FILE
     RESULTS_LOG[$LOGNAME]=1
     elif [[ "slowdebug" == *$SELECTED_JDK* || "debug" == *$SELECTED_JDK* ]] ; then
     echo "FAIL: Slowdebug jdk is selected by default for ${masterX} even though release is present. This is most likely a priority issue." >> $LOG_FILE
     RESULTS_LOG[$LOGNAME]=1
    else
     echo "PASS: Release jdk is selected as expected." >> $LOG_FILE
     RESULTS_LOG[$LOGNAME]=0
    fi
  done
  
#-------------- Test all expected masters exist against a hardcoded list of masters after update
for masterM in $MASTERS_ALL 
  do
    LOGNAME=$masterM"_exists_after_update.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    alternatives --display $masterM >> $LOG_FILE 2>&1
    if [ $? -eq 0 ] ; then 
      echo "PASS: master ${masterM} exists and works" >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=0
    else
      echo "FAIL: master ${masterM} not found!" >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=1
    fi
  done

#-------------- Cleanup the environment and purge all JDK to prepare for next tests
sudo bash ${PURGE_SCRIPT}

#install all java (8,11,17,latest)
#TODO add java-latest-openjdk (currently does not work because our vms dont use epel)
sudo dnf install -y ${RPM_DOWNLOAD_DIR}/*

#-------------- Check if the status is automatic in the newly installed rpms
isAutomatic "java"
isAutomatic "javac"

#TODO verify the masters are still correctly following priority
#-------------- Check that system JDK is selected in case of automatic alternatives after update
sudo dnf update -y ${TEST_RPM_DIR}/*
if isAutomatic ; then
  if [[ $OTOOL_OS_NAME == "el" ]] ; then
    if [[ $OTOOL_OS_VERSION -eq "7" ]] ; then
      VER="1.8.0"
    elif [[ $OTOOL_OS_VERSION -eq "8" ]] ; then
      VER="11"
    elif [[ $OTOOL_OS_VERSION -eq "9" ]] ; then
      VER="11"
    else
      echo "Unimplemented master set for this rhel. This is fatal."
      exit 110
    fi
  elif [[ $OTOOL_OS_NAME == "f" ]] ; then
    if [ $OTOOL_OS_VERSION -gt 35 ] ; then
      VER="17"
    else
      VER="11"
    fi
  else
    echo "Unknown OS, this is fatal"
    exit 111
  fi
  for auto_master in "java javac"
   do
    LOGNAME=$auto_master"_follows_system_jdk_priority.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    alternatives --display $auto_master >> $LOG_FILE 2>&1
    cat $LOG_FILE | grep "link currently" | grep "{$VER}" 
    if [ $? -eq 0 ] ; then
       echo "PASS: The alternatives point to system JDK." >> $LOG_FILE
       RESULTS_LOG[$LOGNAME]=0
    else
       return "FAIL: The alternatives do not point to system JDK." >> $LOG_FILE
       RESULTS_LOG[$LOGNAME]=1
    fi
   done  
else 
  echo "The status is not automatic. Unable to verify masters." 
fi

#-------------- Cleanup the environment and purge all JDK to prepare for next tests
sudo bash ${PURGE_SCRIPT}

#-------------- Iterate over all available JDKs and test various setups----------------
# TODO LATER add implementation for latest - java-$LATEST_VER-openjdk
JDK_LIST="java-17-openjdk java-1.8.0-openjdk java-11-openjdk"
for selected_java in $JDK_LIST
 do
  sudo dnf install -y ${RPM_DOWNLOAD_DIR}*
  #TODO LATER figure out how to properly resolve latest path
  # get latest version from rpm 
  # rpm -q --whatprovides java-latest-openjdk  
  FULL_JDK_STR=$(ls /usr/lib/jvm | grep $selected_java"-" | grep -v "debug")
  JDK_ABSOLUTE_PATH="/usr/lib/jvm/$FULL_JDK_STR"

#-------------- Test behaviour when one of the JDKs is in manual mode and updated with the tested rpms
  #choose one of the javas as a manual
  ls /usr/lib/jvm
  ls $JDK_ABSOLUTE_PATH
  ls $JDK_ABSOLUTE_PATH"/bin"
  #must be "jre/bin" for jdk8
  #TODO currently unable to set java master 100%
  #sudo alternatives --set java $JDK_ABSOLUTE_PATH"/bin/java"
  sudo alternatives --set javac $JDK_ABSOLUTE_PATH"/bin/javac"  
  ##------------- Test that the JDK alternatives manual setup persisted for all masters after the update
  sudo dnf update -y ${TEST_RPM_DIR}/*
  JDK_MASTERS_IT="java javac"
  for java_master in $JDK_MASTERS_IT 
   do
    LOGNAME=$java_master"_persisted_manual_after_update.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    if isAutomatic $java_master ; then
      echo "FAIL: Master $java_master is in automatic mode after update, even though it should be in manual. Failed test." >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=1
      continue
    else
      echo "PASS: Master $java_master is in manual mode after update, that is correct. Continuing the checks."  >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=0
    fi
    echo "Next check if the expected master is selected."
    ###------------- Test that the correct master is selected after the update
    LOGNAME=${java_master}"_persisted_for_${selected_java}_selected_after_update.log"
    LOG_FILE=$LOG_PATH"/"$LOGNAME
    touch $LOG_FILE
    alternatives --display $java_master  >> $LOG_FILE 2>&1
    cat $LOG_FILE | grep "link currently points to $JDK_ABSOLUTE_PATH"
    if $? ; then 
      echo "PASS: The link points to the correct jdk after the update."  >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=0
    else
      echo "FAIL: The link does not point to the correct jdk after the update. The alternatives output follows."  >> $LOG_FILE
      RESULTS_LOG[$LOGNAME]=1
    fi    
   done  
  sudo bash ${PURGE_SCRIPT}
 done

#TODO LATER processing of the results for the xml plugin
tmpXmlBodyFile=$(mktemp)

for logname in "${!RESULTS_LOG[@]}"; 
  do 
  LOCAL_RESULT=${RESULTS_LOG[$logname]}
  LOG_DEST=$LOG_PATH"/"$logname
  if [ $LOCAL_RESULT -eq 0 ] ; then
    PASSED_TESTS=$(($PASSED_TESTS + 1))
    printXmlTest "$SUITE.test" $logname "0.01" >> $tmpXmlBodyFile
  else
    FAILED_TESTS=$(($FAILED_TESTS + 1))
    printXmlTest "$SUITE.test" $logname "0.01" "$LOG_DEST" "$LOG_DEST" >> $tmpXmlBodyFile
  fi
  ALL_TESTS=$(($ALL_TESTS + 1))
done

printXmlHeader $PASSED_TESTS $FAILED_TESTS $ALL_TESTS $SKIPPED_TESTS $SUITE >  $LOG_PATH/$SUITE.jtr.xml
cat $tmpXmlBodyFile >>  $LOG_PATH/$SUITE.jtr.xml
printXmlFooter >>  $LOG_PATH/$SUITE.jtr.xml
rm $tmpXmlBodyFile
pushd $LOG_PATH
  tar -czf  $SUITE.tar.gz $SUITE.jtr.xml
popd

if [ $FAILED_TESTS -eq 0 ] ; then
  exit 0
else 
  echo "There are failed tests: ${FAILED_TESTS} failures out of ${ALL_TESTS}"
  exit 0
fi









