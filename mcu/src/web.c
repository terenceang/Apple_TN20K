#include "web.h"
#include "disks.h"
#include <stdio.h>
#include <string.h>
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#if __has_include("credentials.h")
#include "credentials.h"
#else
#define WIFI_SSID ""
#define WIFI_PASS ""
#endif

#define TAG "web"

static const char PAGE[] =
    "<!doctype html><meta name=viewport content='width=device-width'><title>Apple //e disks</title>"
    "<h1>Disk images</h1>"
    "<p>Drive <select id=d><option>1<option>2</select> "
    "<input type=file id=f accept='.dsk,.do,.po'> <button onclick=up()>Mount</button> <span id=s></span>"
    "<script>async function up(){const f=document.getElementById('f').files[0];if(!f)return;"
    "const e=f.name.split('.').pop().toLowerCase();"
    "const r=await fetch('/disk/'+document.getElementById('d').value+'?ext='+e,{method:'POST',body:f});"
    "document.getElementById('s').textContent=await r.text()}</script>";

static esp_err_t index_get(httpd_req_t *r) {
    return httpd_resp_send(r, PAGE, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t disk_post(httpd_req_t *r) {
    int d = r->uri[6] - '1';                          // "/disk/1" or "/disk/2"
    char q[32] = "", ext[8] = "dsk";
    if (d < 0 || d > 1) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad drive");
    if (httpd_req_get_url_query_str(r, q, sizeof q) == ESP_OK) httpd_query_key_value(q, "ext", ext, sizeof ext);
    bool known = false;
    for (int e = 0; e < 3; e++) known |= !strcmp(ext, DISK_EXTS[e]);
    if (!known)
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "ext must be dsk, do or po");
    if (r->content_len != DISK_BYTES)
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "image must be 143360 bytes");

    FILE *f = fopen(SD_MOUNT "/upload.tmp", "wb");
    if (!f) return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD write failed");
    char buf[1024];
    int left = r->content_len;
    while (left > 0) {
        int n = httpd_req_recv(r, buf, left < (int)sizeof buf ? left : (int)sizeof buf);
        if (n <= 0) { fclose(f); remove(SD_MOUNT "/upload.tmp"); return ESP_FAIL; }
        fwrite(buf, 1, n, f);
        left -= n;
    }
    fclose(f);
    char path[32];
    for (int e = 0; e < 3; e++) {                      // only one image per drive on the card
        disk_path(path, sizeof path, d, DISK_EXTS[e]);
        remove(path);
    }
    disk_path(path, sizeof path, d, ext);
    rename(SD_MOUNT "/upload.tmp", path);
    bool ok = disk_mount(d, path);
    return httpd_resp_sendstr(r, ok ? "mounted" : "not a valid image");
}

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && (id == WIFI_EVENT_STA_START || id == WIFI_EVENT_STA_DISCONNECTED)) {
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "http://" IPSTR "/", IP2STR(&e->ip_info.ip));
    }
}

void web_start(void) {
    if (!WIFI_SSID[0]) { ESP_LOGW(TAG, "no credentials.h: Wi-Fi/HTTP off"); return; }
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));
    wifi_config_t wc = {.sta = {.ssid = WIFI_SSID, .password = WIFI_PASS}};
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());

    httpd_handle_t h = NULL;
    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.stack_size = 8192;
    ESP_ERROR_CHECK(httpd_start(&h, &hc));
    httpd_uri_t i = {.uri = "/", .method = HTTP_GET, .handler = index_get};
    httpd_uri_t p1 = {.uri = "/disk/1", .method = HTTP_POST, .handler = disk_post};
    httpd_uri_t p2 = {.uri = "/disk/2", .method = HTTP_POST, .handler = disk_post};
    httpd_register_uri_handler(h, &i);
    httpd_register_uri_handler(h, &p1);
    httpd_register_uri_handler(h, &p2);
}
