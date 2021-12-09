#!/bin/bash
username=$1
password=$2
if [[ "$username" == "" || "$password" == "" ]]; then
     echo "Usage: avaoauth_htpasswd_creation.sh <user_name> <password>"
     echo "Usage: bash avaoauth_htpasswd_creation.sh admin 'RedHat123!'"
     exit 0
fi

#check if htpasswd  is installed#
if [[ -f "/usr/bin/htpasswd" ]]; then
      IsHtpasswdExisted="YES"
else
      username="admin"
      password="RedHat123!"
      printf "%s\n" "INFO: htpasswd is not present so default user/password will be used: ${username}:${password}"
fi

#create user file if htpasswd is not installed#
if [[ "$IsHtpasswdExisted" == "YES" ]]; then
     htpasswd -c -B -b ./oauth-htpasswd-${username} ${username} "${password}"
     #for NAME in admin leader developer qa-engineer;do htpasswd -B -b /tmp/cluster-users ${NAME} 'RedHat123!';done
else #if no htpasswd installed from dnf install httpd -y, then default user/pass will be used admin / RedHat123!
     printf "%s\n" "INFO: htpasswd tool is not installed on this node/vm, so admin / RedHat123! will be used"
     echo 'admin:$2y$05$YnONbRbA4E/PJhzrdWKwouSL0jCcedlHzxj3r5VykjTu/bB8XG986' >oauth-htpasswd-${username}
fi

#Check if OCP has KUBECONFIG or oc cmd working or not#
printf "%s\n" "INFO: Checking OpenShift login access to cluster e.g. oc login/whoami"
IsOCP=$(oc whoami >/dev/null 2>&1)
if [ $? -ne 0 ]; then
    printf "%s\n" "ERROR: No Access to Openshift cluster, please check your OC login or set your KUBECONFIG env VAR"
    exit 1
fi

#create secret for oauth users#
printf "%s\n" "INFO: Creating secret generic oauth-htpasswd-${username}"
oc create secret generic oauth-htpasswd-${username} --from-file htpasswd=./oauth-htpasswd-${username} -n openshift-config
if [ $? -ne 0 ]; then
    printf "%s\n" "ERROR: Failed to create generic secret for oauth-htpasswd-${username}--from-file htpasswd=./oauth-htpasswd-${username}"
    exit 1
fi

#get oauth cluster and prepare for oauth.yaml#
printf "%s\n" "INFO: Prepare and Create oauth.yaml"
#oc get oauth cluster -o yaml > oauth.yaml
#sed -i 's/spec: {}//g' oauth.yaml
#sed -i '/^$/d' oauth.yaml
cat <<EOF > oauth.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: oauth-htpasswd-${username}
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: oauth-htpasswd-${username}
EOF

printf "%s\n" "INFO: Replace new OAUTH configuration"
oc replace -f oauth.yaml
oc get po -n openshift-authentication|grep oauth

printf "%s\n" "INFO: Waiting for oauth POD to restart and come up..."
sleep 30 #this pod took 2-4+minutes to start trigger the re-creation sometime

#waiting for oath-authentication-xxxx pod to come up first before goes on next step#
n=0
CreatingOnce="NO"
while :; do
   if [[ "$CreatingOnce" == "NO" ]]; then
        readarray -t oauth_pods <<<"$(oc get po -n openshift-authentication|grep oauth)"
        for oauth in "${!oauth_pods[@]}"; do
           oauthpod=$(echo ${oauth_pods[$oauth]}|awk '{print $1 " " $2 " " " is " $3}')
           if [[ ! "$oauthpod"  =~ "1/1" ]]; then
                printf "WARN: %s\n" "oauth-authentication POD is NOT UP yet!"
           fi
           if [[ "$oauthpod" =~ "Creating" ]]; then
                printf "INFO: %s\n" "Oauth POD just started Re-Creating..."
                CreatingOnce="YES"
                break
           fi
        done
   fi
   if [[ "$CreatingOnce" == "YES" ]]; then   
        printf "INFO: %s\n" "Waiting for Oauth POD is fully UP..."
        OauthReplica=$( oc get deploy -n openshift-authentication oauth-openshift -o=jsonpath='{.spec.replicas}' )
        OauthReadiness=$( oc get deploy -n openshift-authentication oauth-openshift|grep oauth-|awk '{print $2}' )
        if [[ "$OauthReadiness" == "${OauthReplica}/${OauthReplica}" ]];then
             break
        fi
   fi
   oc get po -n openshift-authentication
   sleep 2
done

printf "INFO: %s\n" "Adding cluster-role cluster-admin for ${username}"
oc adm policy add-cluster-role-to-user cluster-admin ${username}

#create ingress crt#
printf "INFO: %s\n" "Creating ingress crt certs and login to new user ${username}"
oauthpod=$(oc get po -n openshift-authentication|grep oauth | awk '{print $1}')
oc rsh -n openshift-authentication ${oauthpod} cat /run/secrets/kubernetes.io/serviceaccount/ca.crt > "ingress-ca.crt-${username}"

ApiEndPoint=$(oc whoami --show-console|sed 's/https:\/\/console-openshift-console.apps/https:\/\/api/g')
#if SNO something it requires ingress ca cert#
#the script won't test automatic the new user but just print it out#
printf "%s\n" "INFO: Testing new user name can be done two ways with ingress crt or without"
printf "%s\n" "oc login -u admin -p RedHat123!  ${ApiEndPoint}:6443"
printf "%s\n" "oc login -u admin -p RedHat123!  ${ApiEndPoint}:6443 --certificate-authority=./ingress-ca.crt-${username}"


#delete identify and user#
# oc get user
# oc get identity
# oc get secret -n openshift-config
# oc delete user admin
# oc delete identity ${oauth}-users:admin
# oc delete secret ${oauth}-users -n openshift-config
