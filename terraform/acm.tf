# ACM certificate for HTTPS on the shared ALB, covering all five app
# subdomains via a wildcard. DNS-validated against the same Route 53 hosted
# zone dns.tf already looks up (data.aws_route53_zone.parent) -- no extra
# prerequisite beyond what's already required for the plain-HTTP setup.

resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.dns_zone_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.parent.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
