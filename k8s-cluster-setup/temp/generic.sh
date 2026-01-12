#!/bin/bash

echo "This script is being executed from a remote machine"
echo "This script will create a dummy txt file in the tmp directory"
touch /tmp/dummy.txt
if [[ $? -eq 0 ]];then
    echo "Success"
    # exit 1
else 
    echo "Failure"
    exit 1
fi