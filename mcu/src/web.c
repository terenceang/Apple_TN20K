#include "web.h"
#include "disks.h"
#include "oled.h"
#include <stdio.h>
#include <dirent.h>
#include <string.h>
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "nvs.h"
#if __has_include("credentials.h")
#include "credentials.h"
#else
#define WIFI_SSID ""
#define WIFI_PASS ""
#endif

#define TAG "web"

static const char PAGE[] =
    "<!doctype html><meta name=viewport content='width=device-width'><title>Apple //e disks</title>"
    "<h1>Drives</h1><div id=d></div><h1>Library</h1><div id=l></div>"
    "<p><input type=file id=f accept='.dsk,.do,.po'> <button id=u>Add to library</button> <button data-u=/qr>Show Wi-Fi QR on display</button> <span id=s></span>"
    "<script>const $=i=>document.getElementById(i);"
    "async function P(u,b){$('s').textContent=await(await fetch(u,{method:'POST',body:b})).text();st()}"
    "async function st(){try{const j=await(await fetch('/status')).json();"
    "$('d').innerHTML=j.drives.map((d,i)=>'Drive '+(i+1)+': <b>'+(d.name?d.name+(d.rw?' (rw)':' (ro)'):'empty')"
    "+'</b> <button data-u=/eject/'+(i+1)+'>Eject</button>').join('<br>');"
    "$('l').innerHTML=j.lib.map(n=>n+' <button data-u=/mount/1?name='+n+'>Drive 1</button> "
    "<button data-u=/mount/2?name='+n+'>Drive 2</button> <button data-u=/delete?name='+n+'>Delete</button>')"
    ".join('<br>')||'empty'}catch(e){}}"
    "document.onclick=e=>{const t=e.target,f=$('f').files[0];"
    "if(t.dataset.u)P(t.dataset.u);"
    "else if(t.id=='u'&&f)P('/lib?name='+f.name.replace(/[^A-Za-z0-9._-]/g,'_'),f)};"
    "st();setInterval(st,3000)</script>";

static esp_err_t index_get(httpd_req_t *r) {
    return httpd_resp_send(r, PAGE, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t status_get(httpd_req_t *r) {
    uint8_t g0, g1, fl;
    disks_status(&g0, &g1, &fl);
    char b[280];                       // a directory entry name can be up to 255 bytes
    httpd_resp_set_type(r, "application/json");
    httpd_resp_sendstr_chunk(r, "{\"drives\":[");
    for (int d = 0; d < 2; d++) {
        const char *n = disk_name(d);   // names are [A-Za-z0-9._-]: no JSON escaping needed
        snprintf(b, sizeof b, "%s{\"name\":%s%s%s,\"rw\":%s}", d ? "," : "", n ? "\"" : "", n ? n : "null",
                 n ? "\"" : "", (fl >> d) & 1 ? "true" : "false");
        httpd_resp_sendstr_chunk(r, b);
    }
    httpd_resp_sendstr_chunk(r, "],\"lib\":[");
    DIR *dir = opendir(DISK_DIR);
    bool first = true;
    for (struct dirent *e; dir && (e = readdir(dir));)
        if (disk_name_ok(e->d_name)) {
            snprintf(b, sizeof b, "%s\"%s\"", first ? "" : ",", e->d_name);
            httpd_resp_sendstr_chunk(r, b);
            first = false;
        }
    if (dir) closedir(dir);
    httpd_resp_sendstr_chunk(r, "]}");
    return httpd_resp_sendstr_chunk(r, NULL);
}

// ?name= of a request, checked as a library file name.
static bool query_name(httpd_req_t *r, char *name, size_t n) {
    char q[64];
    return httpd_req_get_url_query_str(r, q, sizeof q) == ESP_OK &&
           httpd_query_key_value(q, "name", name, n) == ESP_OK && disk_name_ok(name);
}

static esp_err_t qr_post(httpd_req_t *r) {
    oled_show_qr();
    return httpd_resp_sendstr(r, "QR code on the display");
}

static esp_err_t eject_post(httpd_req_t *r) {
    disk_eject((int)(intptr_t)r->user_ctx);
    return httpd_resp_sendstr(r, "ejected");
}

static esp_err_t mount_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1];
    if (!query_name(r, name, sizeof name)) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad name");
    return httpd_resp_sendstr(r, disk_mount((int)(intptr_t)r->user_ctx, name) ? "mounted"
                                                                              : "cannot mount (bad image, or in the other drive)");
}

static esp_err_t delete_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1];
    if (!query_name(r, name, sizeof name)) return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "bad name");
    return httpd_resp_sendstr(r, disk_delete(name) ? "deleted" : "no such image");
}

// Add an image to the library; if it replaces one a drive holds, that drive remounts it.
static esp_err_t lib_post(httpd_req_t *r) {
    char name[DISK_NAME_MAX + 1], path[48];
    if (!query_name(r, name, sizeof name))
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "name must be letters, digits . _ - and end in .dsk, .do or .po");
    if (r->content_len != DISK_BYTES)
        return httpd_resp_send_err(r, HTTPD_400_BAD_REQUEST, "image must be 143360 bytes");

    FILE *f = fopen(DISK_DIR "/upload.tmp", "wb");
    if (!f) return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD write failed");
    static char buf[4096];                             // httpd handles one request at a time
    int left = r->content_len;
    while (left > 0) {
        int n = httpd_req_recv(r, buf, left < (int)sizeof buf ? left : (int)sizeof buf);
        if (n <= 0 || fwrite(buf, 1, n, f) != (size_t)n) {
            fclose(f); remove(DISK_DIR "/upload.tmp");
            return n <= 0 ? ESP_FAIL : httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD write failed");
        }
        left -= n;
    }
    fclose(f);
    bool held[2];
    for (int d = 0; d < 2; d++) held[d] = disk_name(d) && !strcmp(disk_name(d), name);
    disk_delete(name);                                 // ejects it everywhere; ok if it was not there
    disk_path(path, sizeof path, name);
    if (rename(DISK_DIR "/upload.tmp", path))
        return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "SD rename failed");
    for (int d = 0; d < 2; d++) if (held[d]) disk_mount(d, name);
    return httpd_resp_sendstr(r, "added");
}

static char ip_str[16] = "no router";
static char ap_ssid[16], ap_pass[9];
const char *web_ap_ssid(void) { return ap_ssid; }
const char *web_ap_pass(void) { return ap_pass; }

// Per-board AP name from the MAC, and a random password made once and kept in NVS.
static void ap_identity(void) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    snprintf(ap_ssid, sizeof ap_ssid, "Apple-%02X%02X", mac[4], mac[5]);
    nvs_handle_t h;
    size_t n = sizeof ap_pass;
    if (nvs_open("web", NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_get_str(h, "ap_pass", ap_pass, &n) != ESP_OK) {
        static const char A[] = "abcdefghjkmnpqrstuvwxyz23456789";   // no look-alikes, no QR-special characters
        for (int i = 0; i < 8; i++) ap_pass[i] = A[esp_random() % (sizeof A - 1)];
        ap_pass[8] = 0;
        nvs_set_str(h, "ap_pass", ap_pass);
        nvs_commit(h);
    }
    nvs_close(h);
}
static volatile bool online;
const char *web_ip(void) { return ip_str; }
bool web_online(void) { return online; }

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && (id == WIFI_EVENT_STA_START || id == WIFI_EVENT_STA_DISCONNECTED) && WIFI_SSID[0]) {
        online = false;
        snprintf(ip_str, sizeof ip_str, "connecting...");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        snprintf(ip_str, sizeof ip_str, IPSTR, IP2STR(&e->ip_info.ip));
        online = true;
        ESP_LOGI(TAG, "http://%s/", ip_str);
    }
}

void web_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();
    if (WIFI_SSID[0]) esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event, NULL));
    // Always an access point (join it with the QR code on the OLED, then browse to
    // 192.168.4.1); also a station when credentials.h names a router.
    ap_identity();
    wifi_config_t ap = {.ap = {.max_connection = 2, .authmode = WIFI_AUTH_WPA2_PSK}};
    strlcpy((char *)ap.ap.ssid, ap_ssid, sizeof ap.ap.ssid);
    strlcpy((char *)ap.ap.password, ap_pass, sizeof ap.ap.password);
    ap.ap.ssid_len = strlen(ap_ssid);
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_SSID[0] ? WIFI_MODE_APSTA : WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    if (WIFI_SSID[0]) {
        wifi_config_t wc = {.sta = {.ssid = WIFI_SSID, .password = WIFI_PASS}};
        ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    }
    ESP_LOGI(TAG, "AP %s / %s: http://192.168.4.1/", ap_ssid, ap_pass);
    ESP_ERROR_CHECK(esp_wifi_start());

    httpd_handle_t h = NULL;
    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    hc.stack_size = 8192;
    ESP_ERROR_CHECK(httpd_start(&h, &hc));
    httpd_uri_t i = {.uri = "/", .method = HTTP_GET, .handler = index_get};
    httpd_uri_t st = {.uri = "/status", .method = HTTP_GET, .handler = status_get};
    httpd_uri_t lib = {.uri = "/lib", .method = HTTP_POST, .handler = lib_post};
    httpd_uri_t del = {.uri = "/delete", .method = HTTP_POST, .handler = delete_post};
    httpd_register_uri_handler(h, &i);
    httpd_register_uri_handler(h, &st);
    httpd_register_uri_handler(h, &lib);
    httpd_uri_t qr = {.uri = "/qr", .method = HTTP_POST, .handler = qr_post};
    httpd_register_uri_handler(h, &del);
    httpd_register_uri_handler(h, &qr);
    static const char *const mt[] = {"/mount/1", "/mount/2"}, *const ej[] = {"/eject/1", "/eject/2"};
    for (int d = 0; d < 2; d++) {
        httpd_uri_t m = {.uri = mt[d], .method = HTTP_POST, .handler = mount_post, .user_ctx = (void *)(intptr_t)d};
        httpd_uri_t e = {.uri = ej[d], .method = HTTP_POST, .handler = eject_post, .user_ctx = (void *)(intptr_t)d};
        httpd_register_uri_handler(h, &m);
        httpd_register_uri_handler(h, &e);
    }
}
