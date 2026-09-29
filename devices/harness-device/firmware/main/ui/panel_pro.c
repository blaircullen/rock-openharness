/*
 * Harness Pro panel: ST7703I, 720x720, MIPI-DSI, two lanes at 480 Mbps.
 *
 * The dial's panel and this one differ in kind, not degree, and the difference decides the shape of this
 * file. The dial partial-renders into two small buffers in internal DMA RAM and pushes them over QSPI
 * (ui/display.c). A DPI panel is scanned out continuously by the DSI peripheral from a framebuffer in
 * PSRAM, so LVGL renders a WHOLE screen into a spare buffer and the flush is a pointer swap — no pixels
 * move. That is why this uses LV_DISPLAY_RENDER_MODE_FULL with the panel's own two framebuffers rather
 * than draw buffers of our own: handing LVGL the memory the panel already scans is what makes the swap
 * free, and it is also what makes it tear-free, because the swap happens between refreshes.
 *
 * Everything the vendor BSP would have carried — the ST7703's power-on register sequence and this
 * panel's DSI timings — comes from waveshare/esp_lcd_st7703 instead. The two config macros below are the
 * whole of it: 38 MHz pixel clock, porches 50/20/50 by 20/4/20, and the init commands inside the driver.
 */
#include "panel.h"

#include "board_pins.h"
#include "display.h"
#include "pro_panel_bus.h"

#include "esp_check.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_heap_caps.h"
#include "esp_log.h"

static const char *TAG = "panel_pro";

static esp_lcd_panel_handle_t s_panel;
static lv_display_t          *s_disp;

/* Brightness and the idle blank both live in pro_panel_bus.c now, because the habitat renderer needs
 * them and has no panel.h. These three are the panel.h names the rest of the firmware calls. */
void panel_set_brightness(uint8_t level) { pro_backlight_set(level); }

/* The idle blank. This panel is backlit, so "off" is the backlight rather than the pixels — cutting the
 * DSI stream instead would take a full re-init to come back from, and the dial's wake is instant. */
static uint8_t s_level_before_blank = 255;
void panel_power(bool on)
{
    if (!on) {
        s_level_before_blank = pro_backlight_level();
        pro_backlight_set(0);
        pro_backlight_enable(false);
    } else {
        pro_backlight_enable(true);
        pro_backlight_set(s_level_before_blank);
    }
}

/* A twelfth of the face. Two buffers of it are 169 KiB of the ~525 KiB internal RAM this board starts
 * with, which leaves room for the audio path that joins later. */
#define DRAW_LINES 60
int panel_draw_lines(void) { return DRAW_LINES; }

static esp_err_t pro_panel_self_test(bool on)
{
    if (!s_panel) return ESP_ERR_INVALID_STATE;
    esp_err_t err = esp_lcd_dpi_panel_set_pattern(s_panel, on ? MIPI_DSI_PATTERN_BAR_VERTICAL
                                                              : MIPI_DSI_PATTERN_NONE);
    /* Logged rather than returned quietly: this is the one call whose failure would leave a blank
     * screen looking exactly like a panel that is not there at all. */
    if (err != ESP_OK) ESP_LOGE(TAG, "pattern %s refused: %s", on ? "on" : "off", esp_err_to_name(err));
    return err;
}

/*
 * The copy into the framebuffer has finished, so LVGL may reuse the draw buffer.
 *
 * ON_COLOR_TRANS_DONE, NOT ON_REFRESH_DONE, and the difference is why the first version of this file
 * drew nothing at all. `on_refresh_done` reports that the panel finished SCANNING a frame, which is
 * what a buffer-switch scheme waits for; `on_color_trans_done` reports that the pixels asked for by
 * draw_bitmap have actually landed, which is what a copying flush waits for. Registering only the
 * former left every flush un-acknowledged: LVGL rendered one frame, called flush, and waited for a
 * release that never came — a blank screen with no error anywhere. (Espressif's own LVGL adapter picks
 * between the two on exactly this distinction; see its v9 bridge.)
 */
static bool on_color_trans_done(esp_lcd_panel_handle_t panel, esp_lcd_dpi_panel_event_data_t *edata, void *ctx)
{
    lv_display_t *disp = (lv_display_t *)ctx;
    lv_display_flush_ready(disp);
    return false;
}

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    /* Blanked: the backlight is off, so nothing would be seen. Ack at once rather than making LVGL wait
     * on a copy whose result nobody can look at — the same rule panel_dial.c follows. */
    if (display_is_asleep()) { lv_display_flush_ready(disp); return; }
    /* Partial render: LVGL has drawn one band into its own buffer and this copies that band into the
     * framebuffer the panel scans. The copy is DMA2D's, not the CPU's (`use_dma2d` in the DPI config). */
    esp_lcd_panel_draw_bitmap(s_panel, area->x1, area->y1, area->x2 + 1, area->y2 + 1, px_map);
    /* flush_ready comes from on_color_trans_done, not from here. */
}

esp_err_t panel_bringup(void)
{
    pro_backlight_init();   /* enable the boost early; duty stays 0 until there is something to show */
    return pro_panel_bus_open(&s_panel, NULL);
}

esp_err_t panel_attach(int draw_lines, lv_display_t **out_display)
{
    esp_err_t err;

    /* Draw buffers in INTERNAL DMA RAM, for the reason display.c gives on the dial: the flush reads
     * these while the CPU writes the next band, and putting both in the same external memory makes the
     * two contend. See panel_draw_lines() for how tall they are and why. */
    /* 64-BYTE ALIGNED, AND THE SIZE ROUNDED UP TO MATCH. That is the L2 cache line, and the PPA reaches
     * these buffers through the cache: a buffer that starts mid-line, or ends mid-line, cannot be
     * invalidated without dragging a neighbour's bytes in or out with it. LVGL is told the same number
     * through CONFIG_LV_DRAW_BUF_ALIGN, and its PPA unit refuses to compile if the two disagree. */
    const size_t line = 64;
    size_t buf_bytes = BSP_LCD_H_RES * draw_lines * (BSP_LCD_BIT_PER_PIXEL / 8);
    buf_bytes = (buf_bytes + line - 1) / line * line;
    uint8_t *buf1 = heap_caps_aligned_alloc(line, buf_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    uint8_t *buf2 = heap_caps_aligned_alloc(line, buf_bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
    if (!buf1 || !buf2) {
        ESP_LOGE(TAG, "draw buffers (%u B x2) would not fit in internal DMA RAM", (unsigned)buf_bytes);
        return ESP_ERR_NO_MEM;
    }

    s_disp = lv_display_create(BSP_LCD_H_RES, BSP_LCD_V_RES);
    if (!s_disp) return ESP_ERR_NO_MEM;
    /* Plain RGB565, NOT the dial's RGB565_SWAPPED: that swap exists because the CO5300 is fed over QSPI
     * in the panel's byte order, and DSI is not. Getting it wrong here is not subtle — the whole screen
     * comes out in the wrong hue. */
    lv_display_set_color_format(s_disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(s_disp, buf1, buf2, buf_bytes, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(s_disp, flush_cb);

    const esp_lcd_dpi_panel_event_callbacks_t cbs = { .on_color_trans_done = on_color_trans_done };
    err = esp_lcd_dpi_panel_register_event_callbacks(s_panel, &cbs, s_disp);
    /* Without this LVGL never gets its buffer back and the screen stays on frame one. Loud, not a warning. */
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "flush-done callback refused (%s) — LVGL would stall after one frame",
                 esp_err_to_name(err));
        return err;
    }

    /*
     * FULL BRIGHTNESS, HERE, BECAUSE NOTHING ELSE WILL DO IT.
     *
     * The dial comes up lit without anyone asking: the last entries of its CO5300 power-on sequence are
     * {0x51, 0xFF} — panel at native maximum — and ui_set_brightness() then dims in SOFTWARE, with a
     * translucent layer over the whole UI. So app_main never calls display_set_brightness() on either
     * board, and a Pro whose backlight was left at the duty backlight_init() set (zero) drew a perfect,
     * invisible screen: the daemon paired, the log said `ui: face: overview`, and the glass was black.
     *
     * Matching the dial means coming up at maximum and letting the UI's own overlay do the dimming.
     * Using this PWM for the user's brightness setting instead — which is what the hardware is for — is
     * a change to ui_screens.c, not to this line.
     */
    panel_set_brightness(255);

    ESP_LOGI(TAG, "panel up · %dx%d · %d lanes @ %d Mbps · framebuffer %u KiB in PSRAM · draw buffers %u KiB x2",
             BSP_LCD_H_RES, BSP_LCD_V_RES, BSP_LCD_DSI_LANES, BSP_LCD_DSI_LANE_MBPS,
             (unsigned)(BSP_LCD_H_RES * BSP_LCD_V_RES * 2 / 1024), (unsigned)(buf_bytes / 1024));

    if (out_display) *out_display = s_disp;
    return ESP_OK;
}
