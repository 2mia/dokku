#!/usr/bin/env bats

load test_helper

setup() {
  [[ -f "$DOKKU_ROOT/VHOST" ]] && cp -f "$DOKKU_ROOT/VHOST" "$DOKKU_ROOT/VHOST.bak"
  [[ -f "$DOKKU_ROOT/HOSTNAME" ]] && cp -f "$DOKKU_ROOT/HOSTNAME" "$DOKKU_ROOT/HOSTNAME.bak"
  create_app
}

teardown() {
  destroy_app 0 $TEST_APP
  [[ -f "$DOKKU_ROOT/VHOST.bak" ]] && mv "$DOKKU_ROOT/VHOST.bak" "$DOKKU_ROOT/VHOST"
  [[ -f "$DOKKU_ROOT/HOSTNAME.bak" ]] && mv "$DOKKU_ROOT/HOSTNAME.bak" "$DOKKU_ROOT/HOSTNAME"
}

assert_ssl_domain() {
  local domain=$1
  assert_app_domain "${domain}"
  assert_http_redirect "http://${domain}" "https://${domain}:443/"
  assert_http_success "https://${domain}"
}

assert_nonssl_domain() {
  local domain=$1
  assert_app_domain "${domain}"
  assert_http_success "http://${domain}"
}

assert_app_domain() {
  local domain=$1
  run /bin/bash -c "dokku domains $TEST_APP | grep -xF ${domain}"
  echo "output: "$output
  echo "status: "$status
  assert_output "${domain}"
}

assert_http_redirect() {
  local from=$1
  local to=$2
  run curl -kSso /dev/null -w "%{redirect_url}" "${from}"
  echo "output: "$output
  echo "status: "$status
  assert_output "${to}"
}

assert_http_success() {
  local url=$1
  run curl -kSso /dev/null -w "%{http_code}" "${url}"
  echo "output: "$output
  echo "status: "$status
  assert_output "200"
}

assert_access_log() {
  local prefix=$1
  run [ -a /var/log/nginx/$prefix-access.log ]
  assert_success
}

assert_error_log() {
  local prefix=$1
  run [ -a /var/log/nginx/$prefix-error.log ]
  assert_success
}

assert_external_port() {
  local CID="$1"; local exit_status="$2"
  local EXTERNAL_PORT_COUNT=$(docker port $CID | wc -l)
  run /bin/bash -c "[[ $EXTERNAL_PORT_COUNT -gt 0 ]]"
  if [[ "$exit_status" == "success" ]]; then
    assert_success
  else
    assert_failure
  fi
}

@test "(nginx-vhosts) nginx (no server tokens)" {
  deploy_app
  run /bin/bash -c "curl -s -D - $(dokku url $TEST_APP) -o /dev/null | egrep '^Server' | egrep '[0-9]+'"
  echo "output: "$output
  echo "status: "$status
  assert_failure
}

@test "(nginx-vhosts) logging" {
  deploy_app
  assert_access_log ${TEST_APP}
  assert_error_log ${TEST_APP}
}

@test "(nginx-vhosts) nginx:build-config (wildcard SSL)" {
  setup_test_tls wildcard
  add_domain "wildcard1.dokku.me"
  add_domain "wildcard2.dokku.me"
  deploy_app
  cat /home/dokku/${TEST_APP}/nginx.conf
  assert_ssl_domain "wildcard1.dokku.me"
  assert_ssl_domain "wildcard2.dokku.me"
}

@test "(nginx-vhosts) nginx:build-config (wildcard SSL & unrelated domain)" {
  destroy_app
  TEST_APP="${TEST_APP}.example.com"
  setup_test_tls wildcard
  deploy_app nodejs-express dokku@dokku.me:$TEST_APP
  run /bin/bash -c "egrep '*.dokku.me' $DOKKU_ROOT/${TEST_APP}/nginx.conf | wc -l"
  assert_output "0"
}

@test "(nginx-vhosts) nginx:build-config (with SSL and Multiple SANs)" {
  setup_test_tls sans
  add_domain "test.dokku.me"
  add_domain "www.test.dokku.me"
  add_domain "www.test.app.dokku.me"
  deploy_app
  assert_ssl_domain "test.dokku.me"
  assert_ssl_domain "www.test.dokku.me"
  assert_ssl_domain "www.test.app.dokku.me"
}

@test "(nginx-vhosts) nginx:build-config (wildcard SSL & custom nginx template)" {
  setup_test_tls wildcard
  add_domain "wildcard1.dokku.me"
  add_domain "wildcard2.dokku.me"
  deploy_app nodejs-express dokku@dokku.me:$TEST_APP custom_ssl_nginx_template
  assert_ssl_domain "wildcard1.dokku.me"
  assert_ssl_domain "wildcard2.dokku.me"
  assert_http_redirect "http://${CUSTOM_TEMPLATE_SSL_DOMAIN}" "https://${CUSTOM_TEMPLATE_SSL_DOMAIN}:443/"
  assert_http_success "https://${CUSTOM_TEMPLATE_SSL_DOMAIN}"
}

@test "(nginx-vhosts) nginx:build-config (custom nginx template)" {
  add_domain "www.test.app.dokku.me"
  deploy_app nodejs-express dokku@dokku.me:$TEST_APP custom_nginx_template
  assert_nonssl_domain "www.test.app.dokku.me"
  assert_http_success "customtemplate.dokku.me"
}

@test "(nginx-vhosts) nginx:build-config (no global VHOST and domains:add)" {
  destroy_app
  rm "$DOKKU_ROOT/VHOST"
  create_app
  add_domain "www.test.app.dokku.me"
  deploy_app
  assert_nonssl_domain "www.test.app.dokku.me"
}

@test "(nginx-vhosts) nginx:build-config (failed validate_nginx)" {
  run deploy_app nodejs-express dokku@dokku.me:$TEST_APP bad_custom_nginx_template
  echo "output: "$output
  echo "status: "$status
  assert_failure
}

@test "(nginx-vhosts) nginx:enable/disable" {
  deploy_app
  assert_nonssl_domain "${TEST_APP}.dokku.me"

  run dokku nginx:disable $TEST_APP
  echo "output: "$output
  echo "status: "$status
  assert_success

  for CID_FILE in $DOKKU_ROOT/$TEST_APP/CONTAINER.web.*; do
    assert_external_port $(< $CID_FILE) success
  done

  run dokku nginx:enable $TEST_APP
  echo "output: "$output
  echo "status: "$status
  assert_success
  assert_http_success "${TEST_APP}.dokku.me"

  for CID_FILE in $DOKKU_ROOT/$TEST_APP/CONTAINER.web.*; do
    assert_external_port $(< $CID_FILE) failure
  done
}
