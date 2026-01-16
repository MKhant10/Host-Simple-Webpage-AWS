provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {}

# create an S3 Bucket
resource "aws_s3_bucket" "site" {
  bucket = var.site_domain
}

# Allow public access to the bucket
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# website configuration for the S3 bucket
resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# set ownership controls to bucket owner preferred
resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# set ACL to public read
resource "aws_s3_bucket_acl" "site" {
  depends_on = [aws_s3_bucket_ownership_controls.site]

  bucket = aws_s3_bucket.site.id
  acl    = "public-read"
}

# set bucket policy to allow public read
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
      }
    ]
  })
  depends_on = [
    aws_s3_bucket_public_access_block.site
  ]
}

# cloudflare settings
# fetch the zone ID for the domain
data "cloudflare_zones" "domain" {
  name = var.site_domain
}

# create CNAME record to point to S3 website endpoint
resource "cloudflare_dns_record" "site_cname" {
  zone_id = data.cloudflare_zones.domain.result[0].id
  name    = var.site_domain
  type    = "CNAME"
  content = aws_s3_bucket_website_configuration.site.website_endpoint
  ttl     = 1
  proxied = true
}
# create CNAME record for www to point to S3 website endpoint
resource "cloudflare_dns_record" "www" {
  zone_id = data.cloudflare_zones.domain.result[0].id
  name    = "www.${var.site_domain}"
  type    = "CNAME"
  content = aws_s3_bucket_website_configuration.site.website_endpoint
  ttl     = 1
  proxied = true
}

# create page rule to always use https
resource "cloudflare_page_rule" "https" {
  zone_id = data.cloudflare_zones.domain.result[0].id
  target  = "*.${var.site_domain}/*"
  actions = {
    always_use_https = true
  }
}

# create ruleset to redirect www to apex
resource "cloudflare_ruleset" "redirect_www_to_root" {
  zone_id     = data.cloudflare_zones.domain.result[0].id
  name        = "redirects"
  description = "Redirect www to apex"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [{
    ref         = "redirect_www_to_root"
    description = "www -> apex"
    enabled     = true

    expression = "(http.host eq \"www.${var.site_domain}\")"
    action     = "redirect"

    action_parameters = {
      from_value = {
        status_code = 301
        target_url = {
          expression = "concat(\"https://${var.site_domain}\", http.request.uri.path)"
        }
        preserve_query_string = true
      }
    }
    }
  ]
}
