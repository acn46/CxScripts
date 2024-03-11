import requests
import getpass
import os
import json

#source_url = input('Source Url:')
source_url = "http://172.35.1.46"
#source_username = input('Source Username:')
source_username = "admin@cx"
#source_password = getpass.getpass('Source Password:')
source_password = ""

# TODO: make these parameters?
######## What to Update ? - Config ########
updateComments = True
updateSeverity = True
updateState = True
updateAssignee = False

######## Results Update Rate - Config ########
resultsProcessPrintRate = 5 #Print Every 5% the Progress of comparing results
resultsUpdateRate = 100 #Update 100 Results at Once

contentType = "text/xml; charset=utf-8"
openSoapEnvelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
closeSoapEnvelope = '</soap:Body></soap:Envelope>'
actionPrefix = 'http://Checkmarx.com'

######## Get URL ########
def get_url(server):
    return f"{server}/CxWebInterface/Portal/CxWebService.asmx"


######## Get Proxy ########
#def get_proxy(url) {
#    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#    return New-WebServiceProxy -Uri "${url}?wsdl"
#}


######## Login ########
def get_token(server, username, password) :
    print (f"getToken: Logging in to {server} as {username}")
    body = {
        "username": username,
        "password": password,
        "grant_type": "password",
        "scope": "offline_access sast_api",
        "client_id": "resource_owner_sast_client",
        "client_secret": "014DF517-39D1-4453-B7B3-9930C563627C",
    }
    api_url = f"{server}/cxrestapi/auth/identity/connect/token"
    headers = {'Content-type': 'application/x-www-form-urlencoded'}

    try:
        response = requests.post(api_url, data=body, headers=headers)
    except Exception as e:
        print(type(e))
    token = json.loads(response.text)
    return token["token_type"] + " " + token["access_token"]

def main():
    srcToken = get_token(source_url, source_username, source_password)

main()