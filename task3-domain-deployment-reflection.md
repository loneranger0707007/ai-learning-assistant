# Reflection: Domain Purchase and HTTPS Public Deployment (Task 3)

## 1. Decision Context

Task 3 requires publishing the AI Learning Assistant through a domain name with HTTPS, behind an Nginx reverse proxy with an additional access-control layer. At the time of writing, Tasks 1 and 2 are complete: the application runs locally and on an Alibaba Cloud ECS instance (cn-guangzhou, public IP `8.163.115.97`) via Docker Compose, exposed on port 14242. Task 3 adds the final public-facing layer.

The course instructor confirmed that ICP filing is not required for this assignment, so the existing Guangzhou ECS can be used directly without provisioning an additional overseas instance. The remaining prerequisite is a registered domain name.

## 2. Domain Purchase Plan

### 2.1 Registrar Selection

I would purchase the domain through **Alibaba Cloud Wanwang (wanwang.aliyun.com)**, the same account that hosts the ECS instance and ACR repository. This choice minimises operational friction: DNS management, ECS, and container registry all live in one console, and there is no need to delegate name servers across providers.

### 2.2 Top-Level Domain Choice

For a coursework deployment, a low-cost TLD is sufficient. Candidates in order of preference:

| TLD  | First-year cost (approx.) | Rationale                                      |
|------|---------------------------|------------------------------------------------|
| `.top`   | ~CNY 1                    | Cheapest; adequate for a temporary service     |
| `.xyz`   | ~CNY 8                    | Widely recognised, low renewal cost            |
| `.site`  | ~CNY 5–10                 | Semantically fits a "web service" use case     |

I would avoid premium or high-renewal TLDs (`.com`, `.ai`) because the domain is only needed for the assignment period and cost control is a stated learning outcome.

### 2.3 Subdomain Strategy

Rather than using the apex domain, I would create a subdomain such as `aila.<mydomain>.top` or `ai.<mydomain>.top`. This keeps the apex free for other uses and makes the purpose of the record explicit.

## 3. DNS Configuration

After purchase, I would add a single DNS record in the Alibaba Cloud DNS console:

| Type | Host Record | Value            | TTL  |
|------|-------------|------------------|------|
| A    | `ai` (or `aila`) | `8.163.115.97` | 600 s (10 min) |

A short TTL (600 seconds) allows rapid correction if the IP changes during testing. I would verify propagation with `dig ai.<mydomain>.top` or `nslookup` before proceeding, ensuring the record resolves to the ECS public IP from both the local machine and the ECS itself.

## 4. Security Group Changes

Before installing Nginx, I would add two inbound rules to the ECS security group:

| Port | Protocol | Source       | Purpose                  |
|------|----------|--------------|--------------------------|
| 80   | TCP      | `0.0.0.0/0`  | HTTP (Certbot challenge + initial proxy test) |
| 443  | TCP      | `0.0.0.0/0`  | HTTPS (final public entry) |

Port 80 must be open to `0.0.0.0/0` because Let's Encrypt's HTTP-01 challenge originates from arbitrary IPs. After the reverse proxy is verified, I would **remove the public inbound rule for port 14242**, so the application container is no longer directly reachable from the internet — all traffic must pass through Nginx.

## 5. Nginx Reverse Proxy

On the ECS, I would install Nginx and create a site configuration at `/etc/nginx/sites-available/ai-agent`:

```nginx
server {
    listen 80;
    server_name ai.<mydomain>.top;

    location / {
        proxy_pass http://127.0.0.1:14242;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 360s;
        proxy_send_timeout 360s;
    }
}
```

Key design choices:
- **`proxy_pass` to `127.0.0.1:14242`** — the container listens on localhost only after the 14242 security-group rule is removed, so Nginx is the sole public entry point.
- **`X-Forwarded-*` headers** — preserve the original client IP and protocol for the application logs.
- **360 s timeouts** — the AI Learning Assistant can take 20–60 seconds to generate artifacts (essays, slides), so the default 60 s Nginx timeout would prematurely close long-running requests.

After enabling the site (`ln -s` to `sites-enabled/`), I would run `nginx -t` to validate the configuration and `systemctl reload nginx` to apply it. I would then confirm `http://ai.<mydomain>.top/ui/` loads correctly over plain HTTP before requesting a certificate.

## 6. HTTPS with Certbot

I would install Certbot with the Nginx plugin and obtain a Let's Encrypt certificate:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d ai.<mydomain>.top
```

Certbot's Nginx plugin automatically modifies the server block to listen on 443 with the issued certificate, configures a redirect from HTTP to HTTPS, and sets up auto-renewal via a systemd timer. I would verify the renewal hook with `certbot renew --dry-run`.

After issuance, I would confirm that `https://ai.<mydomain>.top/ui/` loads with a valid padlock in the browser address bar and that HTTP requests are redirected to HTTPS.

## 7. Access Control (Basic Auth)

The assignment requires an access-control layer at the reverse proxy, separate from the application's built-in BNBU login. I would use HTTP Basic Authentication:

```bash
sudo apt install apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd aila-admin
```

Then add to the Nginx `location /` block:

```nginx
auth_basic "AI Learning Assistant — Restricted";
auth_basic_user_file /etc/nginx/.htpasswd;
```

This adds a second authentication gate: visitors must first enter the Basic Auth credentials before they even reach the application's BNBU login page. The credentials would be stored only on the ECS filesystem (`/etc/nginx/.htpasswd`, mode 640, owned by root:www-data) and never committed to the repository or included in the report.

## 8. Final Hardening

After everything is verified:

1. **Remove port 14242 from the security group** — the container is reachable only via Nginx on 443.
2. **Restrict SSH (port 22)** to my current public IP only (it was previously open during setup).
3. **Verify `docker compose ps`** shows the container still healthy and that `curl http://127.0.0.1:14242/health` returns `{"status":"ok"}` from within the ECS.
4. **Take a screenshot** of the browser showing the HTTPS URL with a valid padlock, the Basic Auth prompt, and the application interface after successful authentication — this is the required evidence for Task 3.

## 9. Cost Reflection

| Item                         | Estimated cost          |
|------------------------------|-------------------------|
| Domain (`.top`, first year)  | ~CNY 1                  |
| ECS (2 vCPU / 2 GB, pay-as-you-go) | ~CNY 0.5–1.0 / hour |
| ACR personal edition         | Free (within quota)     |
| Let's Encrypt certificate    | Free                    |
| Total for assignment period (~1 week) | ~CNY 10–20 |

The deployment is deliberately minimal. The ECS instance can be stopped or released after submission to avoid ongoing charges. The domain can be allowed to expire if no longer needed.

## 10. Security Reflection

- **Secrets management**: the Qwen API key is stored in `data/model-secrets.env` (gitignored, mounted into the container), never in source code or the report. Basic Auth credentials are stored in a hashed htpasswd file on the ECS, not in the repository.
- **Defence in depth**: three layers protect the application — (1) HTTPS encryption in transit, (2) HTTP Basic Auth at the reverse proxy, (3) the application's own BNBU login.
- **Least privilege**: after setup, only ports 80 and 443 are publicly exposed; 14242 is closed and SSH is restricted.
- **Limitation**: Basic Auth sends credentials base64-encoded (not encrypted) on the first request — this is acceptable only because the entire session is wrapped in TLS. For a production service, a stronger mechanism (OAuth, OIDC, or an identity-aware proxy) would be preferable.

## 11. What I Would Do Differently

If I were to repeat this deployment:
- I would provision the ECS in a Hong Kong or Singapore region from the start, eliminating any ICP-filing ambiguity and making port 80/443 available immediately.
- I would use a `docker-compose.prod.yml` override that binds the container port to `127.0.0.1:14242` instead of `0.0.0.0:14242`, so even a misconfigured security group cannot expose the backend directly.
- I would automate the entire Nginx + Certbot + Basic Auth setup with a single shell script or Ansible playbook, rather than running commands manually, to make the deployment reproducible and auditable.
