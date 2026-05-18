#!/bin/bash
# Sets up Route53 CNAME for www.lumiatechs.com → EKS ingress Load Balancer,
# then verifies DNS resolves and the app responds.

echo "=== Pre-flight Checks ==="
echo ""

DOMAIN="www.lumiatechs.com"
BASE_DOMAIN="lumiatechs.com"
NAMESPACE="lumiatech"
MANIFESTS_DIR="kubedefs"

# ─── Check 0: Required tools ─────────────────────────────────────────────────
echo "[Check 0] Verifying required tools..."
MISSING=()
for tool in kubectl aws curl; do
    command -v "$tool" &>/dev/null || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -ne 0 ]; then
    echo "   ❌ Missing required tools: ${MISSING[*]}"
    echo "   Install them then re-run this script."
    exit 1
fi
echo "   ✅ kubectl, aws, curl found"

# DNS resolution tools (optional but used for verification)
HAS_DIG=false; command -v dig &>/dev/null && HAS_DIG=true
HAS_NSLOOKUP=false; command -v nslookup &>/dev/null && HAS_NSLOOKUP=true

# Verify AWS credentials are valid
if ! aws sts get-caller-identity &>/dev/null; then
    echo "   ❌ AWS credentials not configured or expired. Run 'aws configure' or refresh your session."
    exit 1
fi
echo "   ✅ AWS credentials valid"

# Verify kubeconfig reaches the cluster
if ! kubectl cluster-info &>/dev/null; then
    echo "   ❌ Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi
echo "   ✅ Kubernetes cluster reachable"

# ─── Check 1: Namespace ──────────────────────────────────────────────────────
echo ""
echo "[Check 1] Ensuring namespace '$NAMESPACE' exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
# NOTE: This permanently changes the default namespace in your current kubeconfig context.
kubectl config set-context --current --namespace="$NAMESPACE" > /dev/null 2>&1
CURRENT_NS=$(kubectl config view --minify --output 'jsonpath={..namespace}')
if [ "$CURRENT_NS" == "$NAMESPACE" ]; then
    echo "   ✅ Namespace: $CURRENT_NS"
else
    echo "   ❌ Failed to set namespace to $NAMESPACE (current: $CURRENT_NS)"
    exit 1
fi

# ─── Check 2: Apply manifests ────────────────────────────────────────────────
echo ""
echo "[Check 2] Applying manifests from $MANIFESTS_DIR/..."
if [ ! -d "$MANIFESTS_DIR" ]; then
    echo "   ❌ Directory '$MANIFESTS_DIR' not found. Run this script from the project root."
    exit 1
fi
APPLY_OUTPUT=$(kubectl apply -f "$MANIFESTS_DIR/" -n "$NAMESPACE" 2>&1)
APPLY_EXIT=$?
if [ $APPLY_EXIT -eq 0 ]; then
    echo "   ✅ Manifests applied"
else
    echo "   ⚠️  Some manifests had warnings/errors:"
    echo "$APPLY_OUTPUT" | sed 's/^/      /'
    echo "   Continuing..."
fi

# ─── Check 3: Wait for pods ──────────────────────────────────────────────────
echo ""
echo "[Check 3] Waiting for all pods to be Running in '$NAMESPACE'..."
MAX_WAIT=180
ELAPSED=0
INTERVAL=10
while true; do
    # tr -d ' ' strips whitespace that wc -l sometimes includes
    NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | grep -v -E 'Running|Completed' | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | wc -l | tr -d ' ')

    if [ "$TOTAL" -eq 0 ]; then
        echo "   ⚠️  No pods found in namespace $NAMESPACE. Check manifests were applied correctly."
        kubectl get pods -n "$NAMESPACE"
        exit 1
    fi
    if [ "$NOT_READY" -eq 0 ]; then
        echo "   ✅ All $TOTAL pod(s) are Running"
        break
    fi
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "   ❌ Timed out after ${MAX_WAIT}s. Current pod status:"
        kubectl get pods -n "$NAMESPACE"
        echo ""
        echo "   Check logs: kubectl logs -l app=lumia-app -n $NAMESPACE"
        exit 1
    fi
    printf "\r   Waiting for pods... %d/%d ready (%ds elapsed)" \
        $((TOTAL - NOT_READY)) "$TOTAL" "$ELAPSED"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo "=== Pre-flight Checks Passed. Starting Route53 CNAME Configuration ==="
echo ""

# ─── Step 1: Discover Load Balancer DNS ──────────────────────────────────────
echo "1. Getting Load Balancer DNS from ingress-nginx..."
LB_DNS=""
# Probe common service names / namespaces (helm default, manifest default, kube-system fallback)
for candidate in \
    "ingress-nginx ingress-nginx-controller" \
    "ingress-nginx ingress-nginx" \
    "kube-system ingress-nginx-controller"; do
    SVC_NS="${candidate%% *}"
    SVC_NAME="${candidate##* }"
    # Try hostname first (Classic ELB / NLB DNS mode), then IP (NLB IP mode)
    LB_DNS=$(kubectl get svc "$SVC_NAME" -n "$SVC_NS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -z "$LB_DNS" ]; then
        LB_DNS=$(kubectl get svc "$SVC_NAME" -n "$SVC_NS" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    fi
    if [ -n "$LB_DNS" ]; then
        echo "   ✅ Found service '$SVC_NAME' in namespace '$SVC_NS'"
        break
    fi
done

if [ -z "$LB_DNS" ]; then
    echo "❌ Could not find ingress-nginx Load Balancer in any expected location."
    echo "   All LoadBalancer services currently available:"
    kubectl get svc -A --no-headers | grep LoadBalancer || true
    exit 1
fi

echo "   ✅ Load Balancer: $LB_DNS"

# CNAME value must be a hostname, not a bare IP address.
if [[ "$LB_DNS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo ""
    echo "   ❌ Load Balancer returned an IP ($LB_DNS) instead of a hostname."
    echo "   CNAME records require a DNS hostname as their target, not an IP."
    echo "   If you are using an NLB in IP target mode, create an A record instead,"
    echo "   or switch to NLB DNS mode so the service exposes a hostname."
    exit 1
fi

# ─── Step 2: Hosted zone ─────────────────────────────────────────────────────
echo ""
echo "2. Getting Route53 hosted zone ID for $BASE_DOMAIN..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" \
    --output text 2>/dev/null | cut -d'/' -f3)

if [ -z "$HOSTED_ZONE_ID" ]; then
    echo "❌ Could not find a Route53 hosted zone for '$BASE_DOMAIN'."
    echo ""
    echo "   Available hosted zones:"
    aws route53 list-hosted-zones \
        --query "HostedZones[].{Name:Name,Id:Id}" --output table 2>/dev/null || true
    echo ""
    echo "   Manual alternative:"
    echo "   1. AWS Console → Route53 → Hosted Zones → $BASE_DOMAIN"
    echo "   2. Create Record: name=www, type=CNAME, value=$LB_DNS, TTL=300"
    exit 1
fi
echo "   ✅ Hosted Zone ID: $HOSTED_ZONE_ID"

# ─── Step 3: Detect and resolve any record-type conflict ─────────────────────
echo ""
echo "3. Checking for existing records at $DOMAIN..."
EXISTING_RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${DOMAIN}.']" \
    --output json 2>/dev/null)

# Extract the existing record type (empty string = none)
EXISTING_TYPE=$(python3 -c "
import sys, json
recs = json.loads('''$EXISTING_RECORDS''')
print(recs[0]['Type'] if recs else '')
" 2>/dev/null || \
    echo "$EXISTING_RECORDS" | grep -o '"Type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')

if [ -z "$EXISTING_TYPE" ]; then
    echo "   ✅ No existing record — will create fresh CNAME."

elif [ "$EXISTING_TYPE" == "CNAME" ]; then
    EXISTING_VALUE=$(python3 -c "
import sys, json
recs = json.loads('''$EXISTING_RECORDS''')
if recs and recs[0].get('ResourceRecords'):
    print(recs[0]['ResourceRecords'][0]['Value'])
" 2>/dev/null || true)
    if [ "$EXISTING_VALUE" == "$LB_DNS" ]; then
        echo "   ✅ CNAME already points to $LB_DNS — no change needed."
    else
        echo "   ✅ Existing CNAME → $EXISTING_VALUE. Will UPSERT to $LB_DNS."
    fi

else
    # A record (or any other type) exists — must DELETE before we can UPSERT a CNAME.
    # Route53 will reject an UPSERT that changes the record type.
    echo "   ⚠️  Found existing $EXISTING_TYPE record. Must remove it before creating CNAME."
    DELETE_BATCH=$(python3 -c "
import sys, json
recs = json.loads('''$EXISTING_RECORDS''')
if recs:
    print(json.dumps({'Changes': [{'Action': 'DELETE', 'ResourceRecordSet': recs[0]}]}))
" 2>/dev/null)

    if [ -z "$DELETE_BATCH" ]; then
        echo "   ❌ Could not build delete payload. Remove the $EXISTING_TYPE record manually:"
        echo "      aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID"
        exit 1
    fi

    DELETE_OUTPUT=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch "$DELETE_BATCH" 2>&1)
    if [ $? -eq 0 ]; then
        echo "   ✅ Existing $EXISTING_TYPE record deleted."
    else
        echo "   ❌ Failed to delete existing $EXISTING_TYPE record:"
        echo "      $DELETE_OUTPUT"
        exit 1
    fi
fi

# ─── Step 4: Create / update CNAME ───────────────────────────────────────────
echo ""
echo "4. Creating/updating CNAME record..."
echo "   $DOMAIN  →  $LB_DNS"

CHANGE_OUTPUT=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$LB_DNS\"}]
        }
      }]
    }" 2>&1)

if [ $? -ne 0 ]; then
    echo "   ❌ Failed to create CNAME record:"
    echo "      $CHANGE_OUTPUT"
    echo ""
    echo "   Manual alternative:"
    echo "   Record name: www  |  Type: CNAME  |  Value: $LB_DNS  |  TTL: 300"
    exit 1
fi

echo "   ✅ CNAME record created/updated."
CHANGE_ID=$(python3 -c "
import sys, json
d = json.loads('''$CHANGE_OUTPUT''')
print(d['ChangeInfo']['Id'].split('/')[-1])
" 2>/dev/null || \
    echo "$CHANGE_OUTPUT" | grep -o '"Id": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
echo "   Change ID: $CHANGE_ID"

# ─── Step 4b: Wait for Route53 INSYNC ────────────────────────────────────────
if [ -n "$CHANGE_ID" ]; then
    echo ""
    echo "4b. Waiting for Route53 change to be INSYNC..."
    R53_WAIT=0
    R53_MAX=90
    while [ $R53_WAIT -lt $R53_MAX ]; do
        STATUS=$(aws route53 get-change --id "$CHANGE_ID" \
            --query "ChangeInfo.Status" --output text 2>/dev/null || echo "UNKNOWN")
        if [ "$STATUS" == "INSYNC" ]; then
            echo "   ✅ Route53 change is INSYNC."
            break
        fi
        printf "\r   Status: %s (%ds elapsed)" "$STATUS" "$R53_WAIT"
        sleep 5
        R53_WAIT=$((R53_WAIT + 5))
    done
    if [ $R53_WAIT -ge $R53_MAX ]; then
        echo ""
        echo "   ⚠️  Route53 change still PENDING after ${R53_MAX}s — continuing anyway."
    fi
fi

# ─── Step 5: Apply ingress ────────────────────────────────────────────────────
echo ""
echo "5. Configuring ingress..."
if [ -f "kubedefs/appingress.yaml" ]; then
    kubectl apply -f kubedefs/appingress.yaml -n "$NAMESPACE"
    echo "   ✅ Ingress applied."
else
    echo "   ⚠️  kubedefs/appingress.yaml not found — skipping ingress apply."
fi

# ─── Step 6: Verify ingress host matches domain ───────────────────────────────
echo ""
echo "6. Verifying ingress..."
INGRESS_HOST=$(kubectl get ingress lumia-ingress -n "$NAMESPACE" \
    -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "not found")
echo "   Ingress host: $INGRESS_HOST"
if [ "$INGRESS_HOST" != "$DOMAIN" ]; then
    echo "   ⚠️  Ingress host ('$INGRESS_HOST') does not match '$DOMAIN'."
    echo "   Check that appingress.yaml sets the correct host."
fi

# ─── Step 7: DNS propagation wait ────────────────────────────────────────────
echo ""
echo "7. Waiting 60 seconds for DNS propagation..."
for i in $(seq 60 -1 1); do
    printf "\r   Waiting... %2d seconds remaining" $i
    sleep 1
done
echo ""

# ─── Step 8: DNS resolution tests ────────────────────────────────────────────
echo ""
echo "8. Testing DNS resolution..."
dns_lookup() {
    local host="$1" server="$2"
    if $HAS_DIG; then
        dig +short "$host" @"$server" 2>/dev/null | grep -v '\.$' | tail -1
    elif $HAS_NSLOOKUP; then
        nslookup "$host" "$server" 2>/dev/null \
            | awk "/^Address/ && \!/^Address: $server/{print \$2}" | tail -1
    else
        echo ""
    fi
}

if ! $HAS_DIG && ! $HAS_NSLOOKUP; then
    echo "   ⚠️  Neither 'dig' nor 'nslookup' found — skipping DNS resolution test."
else
    for entry in "8.8.8.8:Google" "1.1.1.1:Cloudflare"; do
        SERVER="${entry%%:*}"
        LABEL="${entry##*:}"
        RESULT=$(dns_lookup "$DOMAIN" "$SERVER")
        if [ -z "$RESULT" ]; then
            echo "   ⚠️  $LABEL ($SERVER): not yet propagated"
        else
            echo "   ✅ $LABEL ($SERVER): $RESULT"
        fi
    done
fi

# ─── Step 9: HTTP connectivity tests ─────────────────────────────────────────
echo ""
echo "9. Testing HTTP access..."
HOST_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 -H "Host: $DOMAIN" "http://$LB_DNS" 2>/dev/null || echo "000")
echo "   Ingress routing (Host header): HTTP $HOST_TEST"
if [ "$HOST_TEST" == "404" ] || [ "$HOST_TEST" == "502" ]; then
    echo "   ⚠️  App may have errors. Check: kubectl logs -l app=lumia-app -n $NAMESPACE"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 "http://$DOMAIN" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "302" ]; then
    echo "   ✅ Application is accessible! (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" == "000" ]; then
    echo "   ⚠️  Cannot connect yet — DNS still propagating. Wait 5 more minutes."
else
    echo "   ⚠️  Received HTTP $HTTP_CODE"
fi

echo ""
echo "=========================================="
echo "=== Configuration Complete ==="
echo "=========================================="
echo ""
echo "✅ CNAME:   $DOMAIN  →  $LB_DNS"
echo "✅ Ingress: configured for $DOMAIN"
echo ""
echo "Access your application: http://www.lumiatechs.com"
echo ""
echo "If not working yet:"
echo "  • Wait 5-10 minutes for global DNS propagation"
echo "  • Clear browser cache (Ctrl+F5 / Cmd+Shift+R)"
echo "  • Try incognito/private mode"
echo ""
echo "Verification commands:"
echo "  nslookup www.lumiatechs.com"
echo "  dig www.lumiatechs.com"
echo "  curl -I http://www.lumiatechs.com"
echo ""
echo "Direct Load Balancer (bypasses DNS, works immediately):"
echo "  http://$LB_DNS"
