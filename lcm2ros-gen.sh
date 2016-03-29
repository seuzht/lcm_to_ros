#!/usr/bin/env bash

print_help() {
    if [ $# -gt 0 ] ; then
        echo -e "ERROR: $*\n"
    fi
    echo "Usage: $0 [options] inputlcm"
    echo "Generate CPP and ROS message definitions from lcm messages".
    echo "Options:"
    echo "  -a      Use all files in lcm/*.lcm"
    echo "  -l      Generate LCM to ROS republisher cpp code"
    echo "  -r      Generate ROS to LCM republisher cpp code (use only -l OR -r)"
    echo "  -f      Generate launch file"
    echo "  -h      Print this help and exit"
    echo -e "\nSample usage:"
    echo " $0 -rf lcm/*.lcm"
    echo "     Generate CPP and ROS message defs, republishers and a launch"
    echo "     file for lcm/*.lcm"
    exit 2
}

FULLDIR=false
REPUBS=false
GENLAUNCH=false

while getopts ':arlfh' flag; do
  case "${flag}" in
    a) 
        FULLDIR=true
        echo " * Using all files in lcm/*.lcm" >&2 ;;
    l) 
        $REPUBS && print_help "Specify only one of -l OR -r"
        REPUBS=true
        RFILE=src/lcm2ros_default_republisher.cpp.in
        echo " * Generating LCM to ROS republishers" >&2 ;;
    r) 
        $REPUBS && print_help "Specify only one of -l OR -r"
        REPUBS=true
        RFILE=src/ros2lcm_default_republisher.cpp.in
        echo " * Generating ROS to LCM republishers" >&2 
        ;;
    f) 
        GENLAUNCH=true
        echo " * Generating launch file" >&2 ;;
    h) PRINTHELP=true ;;
    \?) print_help "Invalid option: -$OPTARG" ;;
  esac
done

shift $((OPTIND-1))

if [ $# -eq 0 ] && [ "$FULLDIR" = false ] ; then
    print_help "Must specify either input files or -a"
fi

if [ "$GENLAUNCH" = true ] && [ "$REPUBS" = false ] ; then
    echo "Cannot generate launch file without republishers, include -r option." >&2
    exit 2
fi

if [ "$FULLDIR" = true ] ; then
    INFILES=lcm/*.lcm
else
    INFILES=$@
fi

mkdir -p msg 

if [ "$REPUBS" = true ] ; then
    mkdir -p autosrc
    touch -a autosrc/CMakeLists.txt
fi

if [ "$GENLAUNCH" = true ] ; then
    mkdir -p launch
    LAUNCH_FILE="launch/all_republishers.launch"
    echo  "<launch>" > $LAUNCH_FILE
    echo -e "\t<master auto=\"start\" />" >> $LAUNCH_FILE
    echo -e "\t<group ns=\"lcm_to_ros\">" >>  $LAUNCH_FILE
fi

LCM_TYPES=(int8_t int16_t int32_t int64_t float   double  string boolean byte)
ROS_TYPES=(int8   int16   int32   int64   float32 float64 string bool byte)

N_TYPES=${#LCM_TYPES[@]}

for INFILE in $INFILES ; do
    echo "Processing LCM message file: $INFILE"
    
    # Get the topic name, message type and package name
    TOPIC_NAME=$( echo $INFILE | sed 's:lcm/::; s/.lcm//')
    MESSAGE_TYPE=$(cat $INFILE | awk '/struct/ {print $2}')
    PACKAGE_NAME=$(cat $INFILE | awk -F'[ ;]' '/package/ {print $2}')
    
    # Check if the structre name == filename
    
    # if [ $MESSAGE_NAME != $TOPIC_NAME ]
    # then
    #     echo "ERROR! Structure name '$STRUCT_NAME' does not match filename '$MESSAGE_NAME'"
    #     echo "Edit the lcm file to ensure filename matches structure name and rerun"
    #     continue
    # fi        
    
    echo -n -e "\tGenerating CPP message $PACKAGE_NAME/$MESSAGE_TYPE.hpp with lcm-gen..."
    # Create lcm CPP header (in package subfolder)
    lcm-gen -x $INFILE
    test $? != 0  && { echo "LCM conversion failed, skipping $INFILE"; continue; }
    echo "done."
    
    # Create corresponding ros message
    OUTFILE="msg/$MESSAGE_TYPE.msg"
    echo -n -e "\tCreating ROS message $OUTFILE..."
    echo $(printf '#%.0s' {1..71}) > $OUTFILE
    echo "# This message was automatically generated by the lcm_to_ros package" >>$OUTFILE
    echo "# https://github.com/nrjl/lcm_to_ros, nicholas.lawrance@oregonstate.edu" >>$OUTFILE
    echo -e "$(printf '#%.0s' {1..71})\n#" >>$OUTFILE
    echo "# Source message:    $MESSAGE_NAME.msg" >> $OUTFILE
    echo "# Creation:          $(date '+%c')" >> $OUTFILE
    echo -e "#\n$(printf '#%.0s' {1..71})" >>$OUTFILE
    # sed finds lines in braces {}, removes top and tail lines, leading whitespace and semicolons
    cat $INFILE | sed '/{/,/}/!d' | sed '1d; $d; s/^[ \t]*//; s/;//; ' > tmp
    # Convert datatypes
    for (( i=0; i<${N_TYPES}; i++ ))
    do
        sed -i "s/\b${LCM_TYPES[$i]}\b/${ROS_TYPES[$i]}/" tmp
    done
    # awk to extract array indices (if present)
    cat tmp | awk -F"[][ \t]"+ '{ 
        if (NF < 2)
            x=""
        else if (NF == 2)
            x=$1
        else {
            if ($3 ~ /^[0-9]*$/)
                x=$1"["$3"]"
            else 
                x=$1"[]"
        }; 
        printf "%-20s%s\n", x, $2}' >>$OUTFILE    
    rm tmp
    echo " done."
    
    
    # Generate republisher code
    if [ "$REPUBS" = true ] ; then
        OUTFILE="autosrc/${TOPIC_NAME}_republisher.cpp"
        echo -n -e "\tCreating CPP file $OUTFILE..."
        echo $(printf '/%.0s' {1..71}) > $OUTFILE
        echo "// This source was automatically generated by the lcm_to_ros package" >>$OUTFILE
        echo "// https://github.com/nrjl/lcm_to_ros, nicholas.lawrance@oregonstate.edu" >>$OUTFILE
        echo -e "$(printf '/%.0s' {1..71})\n//" >>$OUTFILE
        echo "// Source message:    $MESSAGE_TYPE.msg" >> $OUTFILE
        echo "// Creation:          $(date '+%c')" >> $OUTFILE
        echo -e "//\n$(printf '/%.0s' {1..71})" >>$OUTFILE
        cat $RFILE | sed "s/@MESSAGE_TYPE@/$MESSAGE_TYPE/g" | \
            sed "s/@TOPIC_NAME@/$TOPIC_NAME/g; s/@PACKAGE_NAME@/$PACKAGE_NAME/g; " >> $OUTFILE
        echo " done."

        # If not already present, add CMakeLists.txt entry
        if ! grep -q "add_executable(\s*${TOPIC_NAME}_republisher" autosrc/CMakeLists.txt ; then        
            echo -n -e "\tAdding entry to autosrc/CMakeLists.txt ..."
            cat src/default_CMakeLists.txt.in | sed "s/@TOPIC_NAME@/$TOPIC_NAME/g" >> autosrc/CMakeLists.txt
            echo " done."
        fi
    fi
    
    if [ "$GENLAUNCH" = true ] ; then    
        echo -n -e "\tAdding entry to $LAUNCH_FILE ..."
        echo -e "\t\t<node pkg=\"lcm_to_ros\" type=\"${TOPIC_NAME}_republisher\" respawn=\"false\" name=\"${TOPIC_NAME}_republisher\" output=\"screen\"/>" >> $LAUNCH_FILE
        echo " done."
    fi
done

if [ "$GENLAUNCH" = true ] ; then  
    echo -e "\t</group>" >>  $LAUNCH_FILE
    echo "</launch>" >> $LAUNCH_FILE
fi
