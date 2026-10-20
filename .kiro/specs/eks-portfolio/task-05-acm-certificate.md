# Task 5 - ACM certificate (two-phase)

## Status
- [ ] Not started / - [x] Done

## Objective
An issued public TLS certificate for `test.name.vn`, with DNS hosted outside AWS.

## Dependencies
Task 3 (state/backend).

## Files to create/modify
- `terraform/infra/acm.tf`, plus variables and outputs

## Implementation guidance
- `aws_acm_certificate`: DNS validation, `create_before_destroy`.
- Output the `domain_validation_options` (name, type, value) and the certificate ARN.
- `aws_acm_certificate_validation` is gated by `acm_wait_for_validation` (default false), so the first apply doesn't block for up to 75 minutes waiting for a record that doesn't exist yet.

## Test requirements
1. Apply.
2. The user adds the validation CNAME at their DNS provider.
3. `aws acm wait certificate-validated --certificate-arn <arn>`
4. Set `acm_wait_for_validation = true` and apply again.

## Demo / acceptance criteria
`aws acm describe-certificate` shows `Status: ISSUED`.

## Interview talking points
- ACM public certificates are free and renew automatically, as long as the validation CNAME stays in place.
- The two-phase apply is a deliberate fix for DNS that Terraform doesn't control.
- TLS terminates at the ALB, and the TLS 1.3 policy is set on the listener.
