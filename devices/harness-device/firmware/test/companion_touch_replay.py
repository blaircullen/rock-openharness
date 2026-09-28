"""Enable the desktop companion in the existing production touch/scene harness.

No board, NVS or serial I/O. Keep the full legacy voice/inbox tests and add the
actual companion request handler, real cJSON, and owner/receipt checks.
"""
import re


def instrument(code, source):
    start = code.index('typedef struct cJSON {')
    end = code.index('static action_t pressed_action;', start)
    code = code[:start] + '#include "cJSON.h"\nenum { JSTRING=cJSON_String,JTRUE=cJSON_True };\n' + code[end:]
    code = '#include "companion.h"\nstatic ht_companion_t desktop_companion;\n' + code
    code = code.replace('static bool queue(action_t a) {', '''
static action_t companion_queued;
static int companion_requests;
static bool queue(action_t a) {
    if (!congestion && a.kind==A_DESKTOP_COMPANION) {companion_requests++;companion_queued=a;}
''')
    handler = re.search(r'^static void companion_request\(int op\)\n\{.*?^\}', source, re.M | re.S)
    assert handler
    code = code.replace('static void render_companion(', handler.group(0) + '\nstatic void render_companion(', 1)
    code = code.replace('static void reset(void) {', 'static void reset(void) {\nht_companion_reset(&desktop_companion);companion_requests=0;')
    code = code.replace('else if (a.kind == A_PET) boops++;', '''else if (a.kind == A_DESKTOP_COMPANION) companion_request(a.value);
    else if (a.kind == A_PET) boops++;''')
    checks = r'''
static void companion_state(const char *phase,const char *stage,uint64_t serial,unsigned epoch) {
    char json[1024];
    snprintf(json,sizeof json,"{\"t\":\"companion.state\",\"v\":1,\"serial\":%llu,\"window\":\"desktop-fixture\",\"epoch\":%u,\"revision\":%llu,\"enabled\":true,\"motion\":true,\"phase\":\"%s\",\"art\":\"fixture\",\"feeling\":{\"emotion\":\"content\",\"reason\":\"settled\"},%s\"egg\":{\"uid\":\"egg-owned\",\"kind\":\"first\",\"stage\":\"%s\"}}",
        (unsigned long long)serial,epoch,(unsigned long long)serial,phase,
        !strcmp(phase,"creature")?"\"creature\":{\"uid\":\"tim-owned\",\"id\":\"tim\",\"name\":\"Tim\",\"version\":\"0.1\",\"seed\":42},":"",stage);
    cJSON *p=cJSON_Parse(json);assert(p);assert(ht_companion_receive(&desktop_companion,p,ms()));cJSON_Delete(p);scene_take();
}
static bool companion_receipt(const char *id,bool ok) {
    cJSON *p=cJSON_CreateObject();cJSON_AddStringToObject(p,"t","companion.action.result");
    cJSON_AddStringToObject(p,"requestId",id);cJSON_AddBoolToObject(p,"ok",ok);
    bool accepted=ht_companion_receive(&desktop_companion,p,ms());cJSON_Delete(p);return accepted;
}
static void companion_checks(void) {
    reset();s.count=0;s.active=-1;companion_state("egg","p0",1,7);
    tap(1000,233,220);assert(!companion_requests&&!starts);
    companion_state("egg","p4",2,7);
    for(int r=0;r<scene.count;r++)if(!strcmp(scene.runs[r].text,"tap to hatch"))
        assert(scene.runs[r].y+scene.runs[r].font->height<HT_NOTIFICATION_Y);

    tap(2000,233,220);assert(companion_requests==1&&!starts&&desktop_companion.pending);
    assert(companion_queued.value==1&&!strcmp(companion_queued.id,"egg-owned"));
    assert(companion_queued.revision==7&&!strcmp(companion_queued.text,"desktop-fixture"));
    assert(!strcmp(desktop_companion.phase,"egg")); // Sending is never a local hatch.
    tap(3000,233,220);assert(companion_requests==1);
    assert(!companion_receipt("stale-request",true)&&desktop_companion.pending);
    assert(companion_receipt(companion_queued.text+81,true)&&!desktop_companion.pending);
    assert(!strcmp(desktop_companion.phase,"egg")); // Receipt still waits for authoritative state.
    s.count=2;s.active=0;companion_state("creature","hatchling",3,7);
    strcpy(s.agents[0].preview,"Latest result lives in the inbox");s.agents[0].recap_ready=true;scene_take();
    for(int r=0;r<scene.count;r++)assert(!strstr(scene.runs[r].text,"Latest result"));
    ht_companion_disconnect(&desktop_companion);s.connected=false;scene_take();
    assert(!desktop_companion.motion&&!s.hit_count&&title_is("Harness offline"));
    s.connected=true;companion_state("creature","hatchling",1,7);
    tap(4000,233,220);assert(starts==1&&recording&&!strcmp(target,"a"));
    tap(5000,233,220);assert(stops==1&&!recording);
    dispatch((action_t){.kind=A_VOICE_ABORT}); // End the fake upload/result lifetime.
    view(COMPANION);scene_take();assert(action_enabled(A_DESKTOP_COMPANION));
    dispatch((action_t){.kind=A_DESKTOP_COMPANION,.value=0});
    assert(companion_requests==2&&companion_queued.value==0&&!strcmp(companion_queued.id,"tim-owned"));
    assert(companion_receipt(companion_queued.text+81,false));assert(desktop_companion.action_error[0]);
    companion_request(2);assert(companion_queued.value==2&&desktop_companion.pending);
    ht_companion_tick(&desktop_companion,desktop_companion.action_deadline,false,true);
    assert(!desktop_companion.pending&&desktop_companion.action_error[0]);
    companion_request(3);assert(companion_queued.value==3&&desktop_companion.pending);
    char old[49];strcpy(old,desktop_companion.action_id);
    companion_state("creature","hatchling",4,8);assert(!desktop_companion.pending&&!desktop_companion.action_error[0]);
    assert(!companion_receipt(old,true));
    congestion=true;companion_request(0);assert(!desktop_companion.pending);
    congestion=false;desktop_companion.enabled=false;companion_request(0);assert(!desktop_companion.pending);
    reset();puts("Desktop companion touch: egg gate, owner, hatch receipt, voice, pet/nap/wake, timeout, account switch, queue refusal PASS");
}
'''
    marker = 'int main(int argc, char **argv) {'
    assert code.count(marker) == 1
    return code.replace(marker, checks + marker + '\ncompanion_checks();\n')
