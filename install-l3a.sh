#!/usr/bin/env bash

export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf

subnet_info=$(curl https://networkcalc.com/api/ip/$(jq -r .metal_network_cidr infra_config.json))
assignable_hosts=$(jq -r .address.assignable_hosts <<< $subnet_info)
first_assignable_host=$(jq -r .address.first_assignable_host <<< $subnet_info)
last_assignable_host=$(jq -r .address.last_assignable_host <<< $subnet_info)
echo $first_assignable_host
echo $last_assignable_host

kubectl label node $uniq_id-controller-primary plane=data

cat << EOF > ns.yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: l3a-v3
  name: l3a-v3

---

apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: observability
  name: observability
EOF
kubectl apply -f ./ns.yaml

cat << EOF > ./sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer

---

apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer

EOF
kubectl apply -f ./sc.yaml

cat << EOF > ./pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-volume
spec:
  capacity:
    storage: 40Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: default-storage
  local:
    path: /data/postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
  claimRef:
    name: data-postgres-postgresql-0
    namespace: l3a-v3

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-volume
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: default-storage
  local:
    path: /data/prometheus
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
  claimRef:
    name: prometheus-server
    namespace: observability
EOF
kubectl apply -f ./pv.yaml

cat << EOF > secret.yaml
apiVersion: v1
data:
  .env: S0FGS0FfQk9PVFNUUkFQX1NFUlZFUlM9cGtjLWxkdmoxLmFwLXNvdXRoZWFzdC0yLmF3cy5jb25mbHVlbnQuY2xvdWQ6OTA5MgpLQUZLQV9TQVNMX0tFWT0ySEM0TVpURjRCNVdLVzRGCktBRktBX1NBU0xfU0VDUkVUPVJIalRJODZ0ZURjMnpQZ3NBalNQMlRSeTdqVzcwSnBVUG5ENmxyZUZadVpMTnU2dVQvQ0I4VWVlWVhlZGtOUWIKCkVUSEVSRVVNX05PREVfSFRUUF9VUkw9aHR0cHM6Ly9tYWlubmV0LmluZnVyYS5pby92My83OWExMzY0YzdmYTY0NTUxOGU1MzJlNDI5MGQ2NGFiZQpFVEhFUkVVTV9OT0RFX1dTX1VSTD13c3M6Ly9tYWlubmV0LmluZnVyYS5pby93cy92My83OWExMzY0YzdmYTY0NTUxOGU1MzJlNDI5MGQ2NGFiZQpFVEhFUkVVTV9OT0RFX1NFQ1JFVD01ZTY2M2M1MzlhNjI0YWQ1YTk2MGNkOGVhNTE2YWU3MgoKU0NIRU1BX1JFR0lTVFJZX1VSTD1odHRwczovL3BzcmMta2p3bWcuYXAtc291dGhlYXN0LTIuYXdzLmNvbmZsdWVudC5jbG91ZApTQ0hFTUFfUkVHSVNUUllfQVBJX0tFWT1YNjdYTTNUUEgzTjZNWTdWClNDSEVNQV9SRUdJU1RSWV9BUElfU0VDUkVUPTcwckRITG1rdlpNaVNMMWsvak90d3MvSlRJTTVSMHNreXhSTDBLY2VaMVlZQTRwKzZPeVJWUzNrNS9ZYWYrb3EKCktVQ09JTl9BUElfS0VZPTYyMDdhM2IyNjViY2VmMDAwMTczMTMwMQpLVUNPSU5fQVBJX1NFQ1JFVD1lMzI3YjhhZC00YjJiLTQ3MzktOGM3NS03NmEyZTIwMWY1OGMKS1VDT0lOX0FQSV9QQVNTUEhSQVNFPW1vbmtleTgzNzY0Cg==
  ca-aiven-cert.pem: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUVRVENDQXFtZ0F3SUJBZ0lVR29PSTdNNXczNHNjT051UzRLaUFib1grVHdvd0RRWUpLb1pJaHZjTkFRRU0KQlFBd09qRTRNRFlHQTFVRUF3d3ZNVEpqTVdaak5qZ3RNREJtWWkwMFlqSmtMVGc0TUdZdE1UQm1OREJtT1RVdwpaV1l3SUZCeWIycGxZM1FnUTBFd0hoY05Nakl3TVRNeE1URXlOekEzV2hjTk16SXdNVEk1TVRFeU56QTNXakE2Ck1UZ3dOZ1lEVlFRRERDOHhNbU14Wm1NMk9DMHdNR1ppTFRSaU1tUXRPRGd3WmkweE1HWTBNR1k1TlRCbFpqQWcKVUhKdmFtVmpkQ0JEUVRDQ0FhSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnR1BBRENDQVlvQ2dnR0JBTUtlV0RsSwpPSFkya2k1WmZBNVF0VzQxRDNnTlFFK1doY2kwVFdWYUYrMVNjU08wbnlpaUdRaWdMczhRMjBKeW5aREwyQ3FEClNKUkticVk2QklISDAxVDRnSUhjaEJhd3J3dW0vd1o4d2MrVEh2THYxRklBd2lSb1JrM3k2UDBKMTY3NUd5MjgKVkprWmdQME1YNGwrbTBYMzJxaStUMlFsZzU0Ui8rUmVKVHV5UWkrVmNKSnJIVFFFTnVDd1ZQOWlGU0Q2SFpGRgpISTBkYjRsZnFtS25Xb3JMMTdXcDhnc3daQlBYcVN3dFBNc1ViaWo1QnZab3dBRmNiRmtwb1NFS2U0WWJwd3BuCnRnY1o5OGI4NTc4WHdaY3E1OTZHY0xWWE5xa2p2MWx0WnFSRWNOanhCQUtMWVlBcy9NTGc2YVhHVWtvZGNQQUoKY09iU0Nvd2lMVUN5U2pHc1g0RE1xTTg1OGtaTzZQZGFoSlU5N1Job0JNdHV1MGxkaUY2QzVhRGpIRlZrRENXNwpRTE5KSnpZbHdEbU9rNFczaTNjMkFlcXpLdDJaeVEzNDBiT05icjl5MktIdDcyT01Cem10cXhJT3hEZWRRWlhRCk1XZGU2OXE4czk0WnROQlh0S3dSRzRpaUJlZlVGbys4cFo3bzc2ZmhuMlVqNWEva1JmaVlaRUtwRVFJREFRQUIKb3o4d1BUQWRCZ05WSFE0RUZnUVVqS2tlSnBtUXNwZGRhRERhZEpMQnV5dFpkTmN3RHdZRFZSMFRCQWd3QmdFQgovd0lCQURBTEJnTlZIUThFQkFNQ0FRWXdEUVlKS29aSWh2Y05BUUVNQlFBRGdnR0JBRGN2WXhjdElJS2xNVGMyCkdwRmcvbXB3eTdweWtMUFQ2c1pFRFp2S3hFOE1TTTdwckNNT1FLWVVQYXlYRTV5bVN2QXZwOXdEUXE3a0RmMnUKRXZIWWU2aVlOU29ZelBkQkcyQ1dOR3RkNDZsbVFRZ1VrM0FieWQva2RRTFE0d2NXL2MvaEtxMHNUeHJaMGJFcwpRb3JmL0dib3NtS1NOMzJla0R5Z2krR1RNRkhjM2xjc0tqb1N4ZUVXNCt5cW5aeWh4OUxEYXorY3RvY0c4OU1KCmJYUCtZUFZGWmpzZUJSYnh6LzdhR244ZUFpK3ZVRlZxMnVDRlNWV1pEd1dDQjgxTWM0TGx1ZmNCc1dMajViZ3EKaVNSVHcxUm9FbzRxWDRVTmZrZVhQZGE5SVo2T2NCN2U0ZjZ6a2lBMzFWc20yWVJVcUNVcWR2endUL2phcmdHVApLaDV2TldpZ1oreVdkWjNJQTRVN1k1dWQwSTk0UWltQlo3L092TkRCOVdPc01UelZhOHZuL1NTR0MxTHhPSGg0ClRsTi9zOEJpYnhBcDZCOGZRaytaOEx1c2NVSFNBRHZwaklyRmZGZ2dqYlhxaUFqNVlEQythYTBiOWJKcFRvRTkKSmdSRllHSHEvSDFyNTE4MnFiSmxvc2lIbDFCdGFETENwVWc2Z1VPaytOU1RKR2F1UWc9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
  jay.cert: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUVPekNDQXFPZ0F3SUJBZ0lVWEhyMGM5UnB3OTdiaG92Y3phSnA0S0hBaUpVd0RRWUpLb1pJaHZjTkFRRU0KQlFBd09qRTRNRFlHQTFVRUF3d3ZNVEpqTVdaak5qZ3RNREJtWWkwMFlqSmtMVGc0TUdZdE1UQm1OREJtT1RVdwpaV1l3SUZCeWIycGxZM1FnUTBFd0hoY05Nakl3TWpBeE1ESTFNVEl4V2hjTk1qUXdOVEF4TURJMU1USXhXakE2Ck1SY3dGUVlEVlFRS0RBNXJZV1pyWVMweE5qQTFOR1EzTWpFUk1BOEdBMVVFQ3d3SWRUZGhOM2t4ZVRjeEREQUsKQmdOVkJBTU1BMHBoZVRDQ0FhSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnR1BBRENDQVlvQ2dnR0JBTkdIWXBIaQptU0ZYeFVONE1XTW5jM2xLMk01WXUxbm9LWjJjdVI3QXpvL1czb3VpL0pQdFJQRTlaZGNXOXM3emhHNWVERVlCCk5aNXk1U1dXb0tiQU5KM3MyT2FvRDJCazhBaUpBYzFNam0vTUpoZlVHNHlRK2ZEelNmS0Rxa05xbktiTmptV0MKSmRaN3hZUGQvclBUa0dQbWRCUjBWcS83ZTg4YkkvTXhaaDVzRnBKdjQ1K3E0TTBycldnN2o5Z1lQQ2tTWE1wVwp1ZmlqVUw3dkppZDBYMUNpekNRSVBqNjJUeGZKb0RGeHNwUWhLWmpGcUhLaG1UVWVOUVVhTE1RSTlYMk8waFh0CjBoZ3BoK0t1ZXN4Z08wdWxsT21uN0h1SmxEMU5EcWxZbDRkQmY4SGNNTWxIMkQyVlFBSk1tSkUvWjQvckhqdWUKN1pHVzUwOWluSTB4Tll6Rm4xRjUxSUFGUTF5WEwwWlFMOXhtdFFjZm95eE1oNHpmazNOdUoxYVlvbENSa254WAoxRUJOT0Q5OFFtcVR1WWNjY3BxekE3WHJFVWs2azgrZ3IrWk50RlJGUmg3Vm1JWWV5THlQeDJ5c3RPUTFQeHBCClg1WTFPZVJSKzdCQ05iamQvREpsM0c1SnZJL3JDMGp3cDFMZEJyVU16d3FYRVY0aFRXUThqNGRRSXdJREFRQUIKb3prd056QWRCZ05WSFE0RUZnUVVVcUdXRXZPNFU2STc3U3JFdGgzWEc2ZE50ZjB3Q1FZRFZSMFRCQUl3QURBTApCZ05WSFE4RUJBTUNCYUF3RFFZSktvWklodmNOQVFFTUJRQURnZ0dCQUtoUis5eFFNWWpFN09sckhwS0NOTkd5CkNoTUx2WWwzY2FrdDBrUi9keG9RUFZyUk5zQ0p2YmNVN0c4SXd4MUlSMEt0cFBmV3VLa0ZaRDlMeTJkb3hrbmMKN0MvRFVWbVd1YmhiTDFJUkd3b2czcXpuRGJQUmpRZ3kvK2lpOHpRQ3hIamxYS1cyYXhGbzUyNUVYVDVtbnc2cwpsUWxqcGNOMXhLZnFuLzNOMm52Q1cyZWJoL0NVRXFtTjlaTHc0bjYra3BEbTJuekN3T0ZpV2hZc1lTV1hqRytDClpMUlpRaHI1ZmJlZ2pHWURMZ1pMelpiTU5lWkVpY2d1QjNDNHptWlZXQi9BdlkySzQ4WEZDdUVrZks1RFFrQzkKVE1UM0haeUJaQWJyMjY0QzZ3WlZlbXZMZHc2TERkaXFJa0lXYmNKcWxIa1phbkhSU1JPVTFBL3I0OWFDbWs3NwpmU0ZKajl6NS9SR1JqMW9XbzI4Q05nOHF4MVliNHBWQmdPd0krblNrMDNGVlVpeGl3TGJSK0NjOTNzcCtOS3RICjFmRXc1NUxhYVNNNmF6NTgyQmwxc1E1dGhrdlJWZlFoeW9hanZ5RHhadk5XQVkycS9rUW1zWVFPYnVtbnBQVncKUnZhZHptRVBuT0hzbWo2YjBiUFVGcVFXbHdZdERFSTdweVlLbHo4dGF3PT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
  jay.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUcvZ0lCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQnVnd2dnYmtBZ0VBQW9JQmdRRFJoMktSNHBraFY4VkQKZURGakozTjVTdGpPV0x0WjZDbWRuTGtld002UDF0NkxvdnlUN1VUeFBXWFhGdmJPODRSdVhneEdBVFdlY3VVbApscUNtd0RTZDdOam1xQTlnWlBBSWlRSE5USTV2ekNZWDFCdU1rUG53ODBueWc2cERhcHltelk1bGdpWFdlOFdECjNmNnowNUJqNW5RVWRGYXYrM3ZQR3lQek1XWWViQmFTYitPZnF1RE5LNjFvTzQvWUdEd3BFbHpLVnJuNG8xQysKN3lZbmRGOVFvc3drQ0Q0K3RrOFh5YUF4Y2JLVUlTbVl4YWh5b1prMUhqVUZHaXpFQ1BWOWp0SVY3ZElZS1lmaQpybnJNWUR0THBaVHBwK3g3aVpROVRRNnBXSmVIUVgvQjNEREpSOWc5bFVBQ1RKaVJQMmVQNng0N251MlJsdWRQCllweU5NVFdNeFo5UmVkU0FCVU5jbHk5R1VDL2NaclVISDZNc1RJZU0zNU56YmlkV21LSlFrWko4VjlSQVRUZy8KZkVKcWs3bUhISEthc3dPMTZ4RkpPcFBQb0svbVRiUlVSVVllMVppR0hzaThqOGRzckxUa05UOGFRVitXTlRuawpVZnV3UWpXNDNmd3laZHh1U2J5UDZ3dEk4S2RTM1FhMURNOEtseEZlSVUxa1BJK0hVQ01DQXdFQUFRS0NBWUF2CnBsSk1TdlA0R1RYTE9qSkJFbCs0WGNVZ2FCMXpQTkQ1L3dJNmRDNkZsNS9Vc2FRdkgrNWx6a2l5dVk0M1VqbnoKdjMrYkMvdGRwVk5uVVBJSCtmMzlURGVuZk9EQ1V6SWpQc1VpSXg3aFhkUHI1MWk4aHR2UWFBT1JHMUJGTktHYgpiWFBNc2VSWStwelllRXZNS1hqVXZ6djJ5dDVMOXkwWTFGdEFteU5XRjg2cVRyZTlQK2NQd2JjVjFUWEpOdm0zCmZXMk10bHhrcHY5ZDdKVUlzL1paS0N5MHBRdEN4OE1FN2QxNFlScnpoUGNvdndxbnh3aEloQzRha3ZGTFE1M20KL2x3TkFramVEZ3dhbndKUkh5cjFMaWx3RW9QdjhJOTVrcCtwZlNzenJXcGRHZWkvc2NEbGNrQXR5TE4vdkdSQgpmRGJTUTlrdmNicGNSZmltRkxpTnVkUEJLVll1eGNON3BTS09KVkd3ck5DdExmM0F0MzNRT1BaZ3J3SkxnUDYxCmQxQmw1Z2xBaE01S0ZrOUlocWNmUEppM0Q0eFhmeThXV1hYVTVkaEdxT0tDV3FEajl5a2RsNDFUUit1cE1VS1cKOTA2SXBrNVdLQlJXMUFQMGN5YXRwaENiUWhHTDVWeHVHR2o2OEd5dG9OMWVFcW4xUGlRTm1kTDJKWGdIdE1FQwpnY0VBOWpTUldwOGQyZGRQSTQrUVRvbE5LdnovS3hxTWlLV0x5VGIwc3A5YXM4WnUxVkczenUxQnBtckdsaW1oCnA5MGE5NU50aVcvQmg1dGtjWXBJS2FaSDhKdVdlSThqT2E2UG9vbXIxbk10czY4MGdOZm9jSUVZZ2xxeXlnSzEKR211Vlh5a3lscnE3YVJVZnJyTUo3aXJWV2tKUHhFSGpzT1pUdlA1RTNpV0ZOZmg3ZmdoM0NIQnVjSVBBaHBjSQoxUmRSY1YxQkw4MUJyZmNhR0FhbC9rRkdFc0w0SkxKYUdlaWVPRGxUKzRJOHZhYzZuOUdRZXE4czNKdVFGU3J4CmxNL05Bb0hCQU5uZFN0ZWtuNkF0ZnRETEpaT3BwcnhUOW1BNEhDbUE5KzFpd2F5VE95bWd3RGd1bEpJRHU3U24KMWVhT1pqVmdDRE15Mjd0N2c2YmJtYllnaGpNMzlFMGNaNytMblRYck5ON2VhV2piZiswYTl6Y0VFbXpVWkEyUQpLMkxWblhvWHRxeVpEaThvQ1ROUnJOcGNPcEV4eTNvbTBEQ1VoT1dndW0zKzBDTzJCeWl2d2NnaUdGcEd0WG9LCitTOGwrTExZR3lwbEJUTVAwcXB2STBDS0ZhY3AxTmJ4YU9STFJJZGcxbzNBYjJESVNuWXljcVU5VGhka3BDSHIKYWsvaXltRlByd0tCd0V2S3pRQlh3V25CVlhSK0NvK1N4dlczNHBtVFY3WHRPSVlkNitCZEhDQUJzemJxTENxQQpjVmhZd0grVG0xZEF3cjk2WEJzV0V6NjZ3SVlQYXIyZm1iL2hOY1l4VWtlOGpDMGVNbzhXNy9mRHRPY0JFR1lwCjU3Q2hXUzdFL0ptQWl3QTdmMzVWUjhKR3BYVXpXcGcrQ1dYNnlmR0IweVV2RXBJNHVGeW1za1oyRXhZdVp1NXIKSmlSdStzSzBGaHo3UzdBWlpDcmlCaGtXMjZxUHlXUG5GanBLV1BkN0RDK3pvNWx0VklRMWlKdGRzcmRtWFJMWApnSGo5VHJLbGdLOHQ5UUtCd1FERG8xK0k0L0RmNHRybFhmZGhjVkFqLy9YWGs2dGViY3kxWkNCcyswMStaVGNYCmZHUzM5aGhCOHhFMjE1cmF4V0Mzc1N6Mlg4VHFPbnIrdkpnbU9GSHVTTnExZkFieG0wUS8rbE9IOE13Z3ZEMVIKTHh2b2xKVkFSTDFoSkZna2dsVHRDd2hjdWtRQXpKQS9DZUVoN3lnOGljd2NROUpQYmhUYm41MkM0L3Zyd21CdQplb2VKMGNNM1U5Rk9VSGZUQ2hMaThCSktOeVJESGtmMnRja1o4b3VKZFFGdk9GUFNpZGhCTkpRUHdleHoxWHR6Ci9PZzZRNHJNVnQyQjNUTkZUVXNDZ2NFQXpQendlWVJMNHJNM0MrVzQ5Z1NKdjZSSW5yV0NoUG02UUk5Z0JmVmcKNWcwemNSVnlUa3Z4ajlDY1c2TGpOZm9RcFFia2VCRVAzZGtNVjFHSVo1TFlEN0ZFdnNDRDhnVkdXMUN6SlUrTgplaDREOTlIQk5mZm1Uc0RTVUpiNlZyeWFxR0x2N0FmTUU1VWwwOVFQUVZLR0NGWk52VGlqclVhbTM2VlYrOFh4CmR0NmJNaXVVM3ZLSXN3ZmpxZVZvL0lDdjZqblZHa2IxQkovTFZiTUxRQ2toYzY0VE82QllzQi9zNmFzV0NKTzYKVFk3eUNHYTBpZ0cxbGZ0NEZsUEJsdkhQCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0K
  ws_server.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUpRUUlCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQ1Nzd2dna25BZ0VBQW9JQ0FRQzJzRDloRXNmSFVxVkUKcmVqdDJEQTl1Y3pUWjVkT01ieElwVUZkci9NczdJbks5MlM2YzREMDVtd3JlQWF6RzdIME5DTnE2cXhvc2VHUworaWtjL3Y5NURZREs2aTBIVlRQL2FNTjZ6cVZ5ME5LY0FhTEZBYjBQR1hqd0FpYnNtVmUrWGJVYWNOU2QwZlRsCkxTQWhWdE5zVjJWckJZSEx0Q2N6a0lwR2dkQmZ3eFdBVG1vcUcvQWFYNm1FaXdUS2ZPVHdWelFpQWgxb2sxVFkKY0VyTCtsUWwxQkd3cUFYMU04M1Q3b01ya1Z1VHgwMjhsclZQYjdqMDY2SlorVzUvQWZjRGlPc2JmcWkzUnFQagpXbldxakNUdkErTmtBM2wyenlFOUc4MC96RWM3N1VJOUVEcEI4eXd4V0s3eWRXa3BWZ2VnWnpIbys4Y1RaY1hyClNqb3NEOGlKTUJUREVYeTFFLy9MYkxTdnJPUmtwR25yUFMySG1nWkVwN1Z4S1Z1Tm5wNS8wTWhkbUpSU1dDWnEKOTdYUk05T2R0MDI5L2Z6b1JBNVg3eXNNT0NBUG9ZeWIrNnU5UWE0Q3BoRzZMdmRHUW0zU1loSmJucEtScHJnTQpBVmtyOTlGeHlJYVhaMEhVK2pQY3NxeWpGRHhWcWNwNzF1YVFKYjgxVWdFSUsyYVJFeTUwMytIVjVudEVhWE5pCm9SMUFMeTBsS3N6WlJTc1NiSWY3ZzFxcW1uTTlkSnY5YnUzVE9rd3FVVWJ3aGgyUDVTbmloaFd1TzhaejIrVTMKeXVGR3gwUDAyQXkvMzZLMXB5V0tNTkhpdWpjOVFIclBwSkFLTjg1YnlPNi9wcDB2c0pFcmk1N21qWmVaTzFBKwpIeFdUUy9nWDc5dllhWFpWYldJblZRS3B6YUpDTlFJREFRQUJBb0lDQUhya2VONGVPaEhWZ0tPQXNhNDl2Y1hvCkZPY3BTbGtwajlUMmhkQTJLa2xRSFNsUjNvcW1aRnRhSGUzbjRlbmVlWWtqQWFoTWtRb2tqdS9HSko0QzAyeGwKTHZ4UkoxVkZkYU1jb0ZNZWE2R2U0KzVhRTFxZlhzU25oL2s4R1Y4VGtEalk1SmtTeVpRWXhycmI3ajgvSHg1RQpkRTdYOTRaR2ZCQnQ3UGFkSU1VcWdHNDlVYUZlQmRoWC9iclJvYmxzNXJ6ZWpJMU1DdWhzSTZrdGNNTmljL1MyCmdlZnFQNGZBLzNiUGZhRnpPTDFpVnVMRUp0ZDIrbDZYbkRFV1g4UkVXQndpb0xWd01LS0pmSG5XUWswbDFUcUwKelExY1lQc1JQdlRTblBHTHcyZUdwUVphd2pYWEZTVmsyTnIxTEhiSURuMVNyZnBpVkhxeC9iL1h3T1llLy9CVgpwZHVQbEN2Vi9JOUxqdCtBVWk2c1lBNU1JcDdFYjdqQlVYYTV4U3daSzB2aXROcnNUOFppYllGUmxyT2R4ZjU2CmZkckQvTjU3QVZpTWV4Z3FUN21yc0Z0RU9mOFo0VnJiMFBmNG9LcUVpZHU4OTc0cGpJNlpvOXhBUFR3THAxVG0KMFVXcEZaSllPek15M1R1eHgveVROR3U5djg4WmwvN1dRQXJ2QTBJSDltNjNacHI3WFVYU2pMeVRGakJmblAvMwpPb2V6OG14ZVhhU002YWhWM3NWM2NkVUxldkkwUzJLL01TQjN4alcveU5MdFY2by9QOGJxSUFicGhZWlp4ZWRBCmpYakdKblJqWUNmUFBkcXRZYmlSUFNETmRPZ1hzT0Eza0NaalJuL2M4SGh1cEFzZjJlR1FyQ2NJZUhrbVBjdmoKRkJHN3kvL3o3L0ZrOEZFUlBmNEpBb0lCQVFEbnk5cTdBUWxsT0FPY211cVVGRDlPM3pWVzVueEZBNFh4K0ttTgozOWpybTA0WjdMVERiUXZoVEZIVEJ0SUE2ejhXR1QzbjJEWlVoZDNKSkcwNjM1Qk1ScFBZYktTU3RZNFJySmIzCmJSSWNpZVJ1WDZHTk9RK0VnTllOSXg1M2VjWHR2M3Bpa1FJREppYmVNSjNzK2FNbm55V0Jrck1HTGw5WStIQUIKbER5anc0VVJTSy9GVHJzV1UvaDFLekY3aHFkanJ1N01ydjZrMEF1WFRZcjJyTnJOTUtpY1MveUpWQjhhTktGSwpTK3pack83QStXVVY0UzlOeVBSMjZpSmc2ZnJwVUZ3aGZCTi9KK1ozM1JaVVVXWlN6U2pHQ0RvR1V6RE9CZHEyCkZWKzdBZHFRUGVTV01aS2FHNmtMbjhhc0UrT0cvRm1zWGp0UTlQblErUXZYSDFnSEFvSUJBUURKdzdFYlJEMzAKdHpCUzFhODRzY1UwWVc2Q1hCNHB6aGZpbklGTmZJZjhFOXFLeDZhOFF1TjA0ODhIdUE5bHJGeEIrSm56ZDVGRQpaU21lMGxnZFVXSStpS3BhblBOSnh5eWdUOHI2aW91amE1Wk1mODVUZkR0NW1CMmxYblI4ZEp2OVRlQWpMbGtPCnZJaTQ0Rkw0ZTRoU0d5MVpBd0VuQVBhWUdjK0NDYktkYmFsNXc2MExzdVpPQW11bHlxckJkbSs1VkJ5SXpSZWsKbGt4MzEvN1ZlWm1FQTJYWFBpd0liQlRjMjNqRlFFVjhOL2FDZzZsTnlkTGhrb1RYNGVuRU9TWnUrRU1RYWp2QwpjQS9sU1owTnRvT2hNVWZtbzNmUFVScU9TKytYdHpaeisvYy9rbFVRRWwxTW5QUys2bUVseDZWZTVhczRRalAyCm90OGtRdWcvR2l6akFvSUJBR09teVVkaUg3YnJTT28zMDZlTHVOZmdzQjdIQWgvdGJ0VmpNUW0wZFo1ODZ5dk0KRHI2QmovenhBYkIybXl3WDlzdzZWOW5ub3h2ZFhVY1BLUUtKZ0pDNk91OXRiYWRBOUczMnhBUmxXTWI2SlVHcQpUVnJZY0NwbjlSNDZ2ZXRoWjgxWlozVWVvRDNZVmhkcDBVdEMyM2k2TzdhajZlRTdhSFJvZ2thN2d3Sm9tVG1nCkJTa1BPdkZUY2xwMUVsWG53dWpoR1ByWU5OT0lPYU4zaThtVzhJNE1ZRUNwamswLzVBc3hHekpFeC9PaEhCZk0KWUQveXlwSm5WV29XS0dkLzBBWWtMU2VjSHdtb2pyVnpVQms1MFlMQmZzajhXbTNEc0JTeWdaK01PdGE3NmtuZQp3Zm9zSDdtdk1KSzF3d1RSbkJ5NU9wZ1cvdXRFRm01WDAxWk52RnNDZ2dFQUNQZlN5blI1RUlTSCtGYVpLRHIyCm1nSnVxQXF5S0llSmxrQUFtMUlhdFVDb3FSeUFzOE9CV3JPNWd3MVNXZUdVWkRaSm1ZSEtDakU0N1Y5S0hWdDkKczJ2ZHJwTmxXUFVxYmFHK1V1NlBrRjc2MmtHZ0NTUHZmTk1mRmplaGs5cVhDR1pLdlNXVlBjdHhoRTRzUWZFegp1UHFPUkhPV3ZJWVZiK05OenVqaGNJL3NSWVpHRGN3UTRvekcvaUtJL25wbU11V2pNdzF5ckpVbHB2b0owTEZMCitvc3dIcVlielBBSTZWd3ovUWlEVGljcXBOaDNVUWJVZ2NSQ2RWb01TdldEV05GZUliK25FbGhxekhVK0x0cmEKOVBJODBPcVpLN1RlS2s4RHdrbVplUVJORkIxTC9KL2tWOEJ1UElJc2VVSnJmbEZWRC9ZWld6QVlIUU9BVVRXMwpvd0tDQVFBdzVzeCtNR2VOSC9iNHpxRDdveG1zT29oM0ZEQ2ZCa1ErSGdlNXlTWjljTmN0N2VTNnNpT1RGUU9NCmRmTUtHOWgzcEExTnF1OGhHUUEvMUx4QmVYb1c0TnhrSmo5V04wMEJTTTRhSU92b1d3NlU1Zi9HUXkxWHJVTWwKQWJaVlFrM2N2TSs3dHlXN2FVTVREa0ljcGtvRnpkRS9lckttdzVYOFpLc003cE8zSTBTc2tRYkdpRGJuUTVpVgpUYTR0ZHRkeGdBWXFQVW9XUWYzdG5PcEROOG5kTWNFNGNwRnZkSURsL2lOdFF4eHpSYUlUMlhHYVoxcS80OFUwCkhENXpoUWxBSWNMZ2JQd29JZm9sWjhaSDRKaCt2a3dKdlA4Q1YzMjBNQkFOdkxSRENCZjhMRkdxMW1rQzlmT20KN3pnZ1VwYVV3Q1I1clNHVnM4dmdHSUMzaG9xcQotLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tCg==
  ws_server_cert.pem: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZYekNDQTBlZ0F3SUJBZ0lVUUZSeTdwTnk0M2hrQkJCcWJOQytwMDBvTmNRd0RRWUpLb1pJaHZjTkFRRUwKQlFBd1B6RUxNQWtHQTFVRUJoTUNRVlV4RERBS0JnTlZCQWdNQTA1VFZ6RVBNQTBHQTFVRUJ3d0dVMWxFVGtWWgpNUkV3RHdZRFZRUUtEQWhSZFdGdWRFUkJUekFlRncweU1qQXlNRGt3T1RRd05EbGFGdzB6TWpBeU1EY3dPVFF3Ck5EbGFNRDh4Q3pBSkJnTlZCQVlUQWtGVk1Rd3dDZ1lEVlFRSURBTk9VMWN4RHpBTkJnTlZCQWNNQmxOWlJFNUYKV1RFUk1BOEdBMVVFQ2d3SVVYVmhiblJFUVU4d2dnSWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUNEd0F3Z2dJSwpBb0lDQVFDMnNEOWhFc2ZIVXFWRXJlanQyREE5dWN6VFo1ZE9NYnhJcFVGZHIvTXM3SW5LOTJTNmM0RDA1bXdyCmVBYXpHN0gwTkNOcTZxeG9zZUdTK2lrYy92OTVEWURLNmkwSFZUUC9hTU42enFWeTBOS2NBYUxGQWIwUEdYancKQWlic21WZStYYlVhY05TZDBmVGxMU0FoVnROc1YyVnJCWUhMdENjemtJcEdnZEJmd3hXQVRtb3FHL0FhWDZtRQppd1RLZk9Ud1Z6UWlBaDFvazFUWWNFckwrbFFsMUJHd3FBWDFNODNUN29NcmtWdVR4MDI4bHJWUGI3ajA2NkpaCitXNS9BZmNEaU9zYmZxaTNScVBqV25XcWpDVHZBK05rQTNsMnp5RTlHODAvekVjNzdVSTlFRHBCOHl3eFdLN3kKZFdrcFZnZWdaekhvKzhjVFpjWHJTam9zRDhpSk1CVERFWHkxRS8vTGJMU3ZyT1JrcEduclBTMkhtZ1pFcDdWeApLVnVObnA1LzBNaGRtSlJTV0NacTk3WFJNOU9kdDAyOS9mem9SQTVYN3lzTU9DQVBvWXliKzZ1OVFhNENwaEc2Ckx2ZEdRbTNTWWhKYm5wS1JwcmdNQVZrcjk5Rnh5SWFYWjBIVStqUGNzcXlqRkR4VnFjcDcxdWFRSmI4MVVnRUkKSzJhUkV5NTAzK0hWNW50RWFYTmlvUjFBTHkwbEtzelpSU3NTYklmN2cxcXFtbk05ZEp2OWJ1M1RPa3dxVVVidwpoaDJQNVNuaWhoV3VPOFp6MitVM3l1Rkd4MFAwMkF5LzM2SzFweVdLTU5IaXVqYzlRSHJQcEpBS044NWJ5TzYvCnBwMHZzSkVyaTU3bWpaZVpPMUErSHhXVFMvZ1g3OXZZYVhaVmJXSW5WUUtwemFKQ05RSURBUUFCbzFNd1VUQWQKQmdOVkhRNEVGZ1FVdEkwMnU1T255SUNKTzFlalZSNGx2VkJlb1h3d0h3WURWUjBqQkJnd0ZvQVV0STAydTVPbgp5SUNKTzFlalZSNGx2VkJlb1h3d0R3WURWUjBUQVFIL0JBVXdBd0VCL3pBTkJna3Foa2lHOXcwQkFRc0ZBQU9DCkFnRUFWRitCbUFKazZxL2xsN2FrVHVaQWxpMTc5ZXRNT1JMWkVmdzNpb0x2UTlwNGVBNEt5cUJJZjFlQ2k5aUQKRTJISlhhVjlCOWh1SkxCRUwvU0hJcFRTSXlScmMxaXVteWswbjNwSk1vTWdNTm43OVdmOTN1disyblQvSlBIQQpUdVJrWEFndDVianFYdmRTZUZ2eGVHNVZqR3ZGQ3pCMy9XOVVaNnZFeTQwbXB6akJBOGM2MXZlOTRqN3duMHBwClZFbG1jbmdtR1dKR0NTeFcyK3YvRlFEOVNpL2Y2Y2psZ3dXZm9BN2Fhem1FV1FVMndRZXBTejZ3Q2VsMUhYVHkKa2dSZklaVXJ5cGRwMXJMZjlNUHFkcW9tNU1ZSWZCRFZaSVczbGVDYUVQR2c1b2xYeHJiRFhQVXhWMGNCY3dBKwpHZ0xXZ3B5Q0c0bHlhcld3cHVEUW5zdnlnd1VDUFg0YzZwZGVvQUJrWld4aDQrOFJpaHVLQnh3L095MUEzSERLClF4R3VjWDkzMjJtdTNMZWoxUlY3TGN0dnY5bTBSRThOdlNPeDlLOW0rUk42ZVVuNmRYclBJQ0pnV2o5OEVSMkYKbXBqbGY2bldISm4zNmQ3UEhxampGMmtRK09WYm9zdy9FWDJlSmZ3VVRQQWZidWdRRWJ1Z0UxSXl0QittWFVOUgpZZlhhUnBIdWlGUSt6SHFhWmR2QWorQUFFYk1PaDcvZGREaW5DY0FSMmJ6L2FsOU1hMFhsdGJkRlNmbkZnWFlKCjd0ZjBucU9FZE5PYzJKSTd2MCthODJtaGFYM0lOeWZHRHJuck9MWW8zNXFDR3NIWW9qTDZTNXVMWkdjT0RWVGQKRnRmbXRabW9wRGJGS2xvT3RFakdhY2h6UDlOaUIyZnRsYm1uWWkyS1VMdGVyN3M9Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K
kind: Secret
metadata:
  name: l3a-secrets
  namespace: l3a-v3
type: Opaque
EOF
kubectl apply -f ./secret.yaml

pushd infra-helm-charts
git checkout feature/l3a-v3-install

pushd cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
                       --namespace cert-manager \
                       --create-namespace \
                       --version v1.12.1 \
                       --set installCRDs=true
sleep 10

cat << EOF > ./issuer.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: l3a-v3
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@l3a.xyz
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: l3a-v3
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@l3a.xyz
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: observability
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@l3a.xyz
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: observability
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@l3a.xyz
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx
EOF
kubectl apply -f ./issuer.yaml

cat << EOF > ./cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: query-$uniq_id-tech-l3a-xyz-tls-static
  namespace: l3a-v3
spec:
  secretName: query-$uniq_id-tech-l3a-xyz-tls-static
  issuerRef:
    name: letsencrypt-prod
  dnsNames:
  - 'query.$uniq_id.tech.l3atom.com'
EOF
kubectl apply -f ./cert.yaml
popd

pushd ingress-nginx
echo "ingctl time with $first_assignable_host"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install -n kube-system ingctl ingress-nginx/ingress-nginx \
                                      --version v4.7.0 \
                                      --set controller.service.loadBalancerIP=$first_assignable_host
sleep 10
popd

pushd postgresql
echo "postgres time with $last_assignable_host"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency build
helm upgrade --install -n l3a-v3 postgres bitnami/postgresql \
                                 --version v12.2.4 \
                                 --set auth.database=superset \
                                 --set primary.service.loadBalancerIP=$last_assignable_host \
                                 -f baremetal.yaml

sleep 10
popd

pushd superset
export POSTGRES_PASSWORD=$(kubectl get secret --namespace l3a-v3 postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
export SUPERSET_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
helm upgrade --install -n l3a-v3 superset . \
                                 --set "init.adminUser.password=$SUPERSET_PASSWORD" \
                                 --set "ingress.hosts[0]=query.$uniq_id.tech.l3atom.com" \
                                 --set "ingress.tls[0].secretName=query-$uniq_id-tech-l3a-xyz-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=query.$uniq_id.tech.l3atom.com" \
                                 --set "supersetNode.connections.db_pass=$POSTGRES_PASSWORD" \
                                 -f baremetal.yaml
sleep 10
popd

pushd prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm dependency build
helm upgrade --install -n observability prometheus prometheus-community/prometheus \
                                 --version 15.17.0 \
                                 -f baremetal.yaml

sleep 10
popd

pushd grafana
helm upgrade --install -n observability grafana . \
                                 --set 'dashboards.default.l3a-v3.file=""' \
                                 --set "ingress.hosts[0]=stats.$uniq_id.tech.l3atom.com" \
                                 --set "ingress.tls[0].secretName=stats-$uniq_id-tech-l3a-com-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=stats.$uniq_id.tech.l3atom.com" \
                                 -f baremetal.yaml

sleep 30
admin_user_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-user}" | base64 -d)
admin_password_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-password}" | base64 -d)
prometheus_dashboard_uid_grafana=$(curl https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.tech.l3atom.com/api/datasources/name/Prometheus | jq -r .uid)

sed "s/relace-with-real-uid/$prometheus_dashboard_uid_grafana/" ./dashboards/l3a-v3-dashboard.template.json > ./dashboards/l3a-v3-dashboard.json

helm upgrade --install -n observability grafana . \
                                 --set 'dashboards.default.l3a-v3.file=dashboards/l3a-v3-dashboard.json' \
                                 --set "ingress.hosts[0]=stats.$uniq_id.tech.l3atom.com" \
                                 --set "ingress.tls[0].secretName=stats-$uniq_id-tech-l3a-com-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=stats.$uniq_id.tech.l3atom.com" \
                                 -f baremetal.yaml

sleep 10
popd

pushd confluent-for-kubernetes
kubectl create ns confluent

helm repo add confluentinc https://packages.confluent.io/helm
helm dependency build
helm upgrade --install -n confluent confluent-operator confluentinc/confluent-for-kubernetes \
                                 --version 0.771.13 \
                                 -f baremetal.yaml
sleep 10

echo "creating zookeepers"
kubectl apply -f ./crs/zookeeper.yaml
sleep 10

echo "patching zookeepers"
kubectl patch -n confluent pvc/data-zookeeper-0 -p '{"spec":{"volumeName":"data-zookeeper-volume"}}'
kubectl patch -n confluent pvc/txnlog-zookeeper-0 -p '{"spec":{"volumeName":"logs-zookeeper-volume"}}'
sleep 2

cat << EOF > ./zookeeper-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-zookeeper-volume
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/zookeeper-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: logs-zookeeper-volume
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/zookeeper-logs
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
EOF

echo "creating zookeeper pv"
kubectl apply -f ./zookeeper-pv.yaml
sleep 10
echo "recycle zookeeper pods"
kubectl delete -n confluent pod/zookeeper-0

echo "creating brokers"
kubectl apply -f ./crs/broker.yaml
sleep 10
echo "patching brokers"
kubectl patch -n confluent pvc/data0-kafka-0 -p '{"spec":{"volumeName":"data-broker0-volume"}}'
kubectl patch -n confluent pvc/data0-kafka-1 -p '{"spec":{"volumeName":"data-broker1-volume"}}'
kubectl patch -n confluent pvc/data0-kafka-2 -p '{"spec":{"volumeName":"data-broker2-volume"}}'
sleep 2

cat << EOF > ./broker-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker0-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-00

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker1-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-01

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker2-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-02
EOF

echo "creating broker pv"
kubectl apply -f ./broker-pv.yaml
sleep 10
echo "recycling brokers"
kubectl delete -n confluent pod/kafka-0 pod/kafka-1 pod/kafka-2
