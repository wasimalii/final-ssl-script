#!/bin/bash
# ************* USAGE ***************
# Example :- ./scrpt.sh trackier-app -vvvv
# step-1: login to the ansible server.
# step-2: execute the script ./scrpt.sh arg1 arg2  
# Key-points:- arg1 will be your cert name for which you want to generate the ssl (trackier-app,click-trackier,rest-ap,conversion-tracker) 
# and arg2 will be for the verbose ouput (-vvvv) 

touch /home/$(whoami)/proxy.txt
touch /home/$(whoami)/user_input.txt

# Using case for different types of load balancers
case "$1" in

    "click-tracker")
    echo "vn-go-clicktracker-target-proxy" >> /home/$(whoami)/proxy.txt
    echo "testing-vn-go-clicktracker-target-proxy" >> /home/$(whoami)/proxy.txt
    echo "$1" > /home/$(whoami)/user_input.txt
    proxy="vn-go-clicktracker-target-proxy"
    ;;

    "conversion-tracker")
    echo "conv-tracker-target-proxy" > /home/$(whoami)/proxy.txt
    echo "$1" > /home/$(whoami)/user_input.txt
    proxy="conv-tracker-target-proxy"

    ;;

    "rest-api")
    echo "trackier-api-target-proxy-2" >> /home/$(whoami)/proxy.txt
    echo "trackier-api-temp-target-proxy-2" >> /home/$(whoami)/proxy.txt
    echo "$1" > /home/$(whoami)/user_input.txt
    proxy="trackier-api-target-proxy-2"

    ;;

    "trackier-app")
    echo "trackier-lb-target-proxy-2" >> /home/$(whoami)/proxy.txt
    echo "testing-trackier-lb-target-proxy-2" >> /home/$(whoami)/proxy.txt
    echo "$1" > /home/$(whoami)/user_input.txt
    proxy="trackier-lb-target-proxy-2"
    ;;

    *)
    echo "No SSL Certs Provided"
    ;;
esac

# Getting ssl cert's from target proxy and store it in a variable.
ssl_cert_list=$(gcloud beta compute target-https-proxies describe $proxy | grep $1 | awk '/sslCertificates/ {print $0}' | cut -d "/" -f 10)

# Using loop to retreive the SAN names of all the SSl cert's defined in our target proxy
for i in ${ssl_cert_list// / }
do
    echo "******** Creating necessary files **************"
    touch /home/$(whoami)/f{1..8}.txt
    touch /home/$(whoami)/fail_domain.txt
    touch /home/$(whoami)/ssl-log.json
    echo "$i" > /home/$(whoami)/f5.txt

    # Retreiving SAN names and store it in a variable
    san_name=$(gcloud compute ssl-certificates describe "$i" --format="get(subjectAlternativeNames)")

    # Diging the domains & if any domains fails append that domain in fail_domain.txt file.
    trim=$(echo "$san_name" | tr ';' ' ')
    for j in ${trim}
    do
        dig "$j" CNAME | grep -e "vnative" -e "trackier" -e "trperf"  > /dev/null
        if [ $? -eq 0 ]
            then
                echo "$j" >> /home/$(whoami)/f6.txt
                dig_domain=$(cat /home/$(whoami)/f6.txt | tr '\n' ' ')
            else
                echo -e "\n FAILED $j \n"
                echo "Failed Domains - $j" >> /home/$(whoami)/fail_domain.txt
                echo "$j" >> /home/$(whoami)/f7.txt
                fail_domain=$(cat /home/$(whoami)/f7.txt)  # creating fail_domain as a varaible for later user in ssl-log.json file
        fi
    done
    
    # Condition if domains fails then ask for user input to proceed with the ssl-generation process or not.
    if [ -s  /home/$(whoami)/f7.txt ]
        then
            read -p "Do you  still want to proceed to generate the ssl cert's? (y/n) " yn
    fi
    case $yn in
        y ) echo ok, we will proceed;;
        n ) echo exiting...;
                exit;;
    esac

    # Creating necessary variables to use in for loop.
    domain_name=$(echo "$dig_domain" | cut -d " " -f 1)
    echo "$domain_name"  > /home/$(whoami)/f4.txt
    san_list=$(echo "$dig_domain" | cut -d ' ' -f 2-)
    echo "$san_list"

    # loop to append the domains to the file for later use in ansible playbook.
    for k in ${san_list// / }
    do
       # echo $k
        echo "$(cat /home/$(whoami)/f1.txt)DNS:$k," > /home/$(whoami)/f1.txt
        echo "$k" >> /home/$(whoami)/f2.txt
    done
    echo "$(cat /home/$(whoami)/f1.txt)" | rev | cut -c 2- | rev > f3.txt

    # Running ansible playbook for generating the ssl cert's
    echo "********************** playbook started *********************************"
    ansible-playbook play.yml --connection=local $2
    
    # Creating necessary variables for use in ssl-log.json files
    new_cert=$(cat /home/$(whoami)/f8.txt)
    d=`date`

    # Below cmd will creating the log files in .json format
    cert_json=$(jq -n --arg Old-cert "$i" \
              --arg new-cert "$new_cert" \
              --arg failed-domains "$fail_domain" \
              '$ARGS.named'
    )
    log_json=$(jq -n --arg proxy-name "$1" \
              --arg date "$d" \
              --arg proxy "$proxy" \
              --arg user "$USER" \
              --argjson certificates "[$cert_json]" \
              '$ARGS.named'
    )
    echo "$log_json" > /home/$(whoami)/ssl-log.json

    # Sending ssl-log.json file data to database using curl
    curl -vi 'http://10.132.0.49:5049' -d "@ssl-log.json" -H "Content-Type: application/json"

    cd /home/$(whoami)/ && sudo rm -rf certs account keys csrs
    rm /home/$(whoami)/f{1..8}.txt
done
# Removing files
rm /home/$(whoami)/proxy.txt
rm /home/$(whoami)/user_input.txt
