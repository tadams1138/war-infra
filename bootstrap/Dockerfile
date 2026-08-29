# Bootstrap placeholder image — see specs/war-infra-spec.md §15.2 and
# terraform/modules/compute/main.tf.
#
# terraform/modules/compute/main.tf creates the App Platform app with a
# hardcoded placeholder image so that `terraform apply` can create the app at
# all before any real deploy has ever run; platform/{env}.yaml then replaces
# the spec on the first pipeline deploy. That placeholder must actually start
# and pass App Platform's health check on its own, with zero configuration —
# it cannot be war-api's real image, which requires DATABASE_URL and other
# secrets it cannot have at bootstrap time and exits non-zero without them.
# A public Docker Hub image was tried and rejected outright by the provider
# ("Image does not exist or is private" — DOCKER_HUB registry_type is broken
# here even for real public images), so this trivial image is built and
# pushed straight into DOCR instead, satisfying both constraints: a real
# DOCR image, and one that boots with nothing but itself.
FROM busybox:stable

RUN mkdir -p /www && \
    echo "war bootstrap placeholder — see specs/war-infra-spec.md §15.2" > /www/index.html

EXPOSE 8080

CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
