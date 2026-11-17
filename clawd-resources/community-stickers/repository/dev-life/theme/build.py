# SPDX-License-Identifier: MIT
# License: ../../LICENSE
"""
Builds the clawd-on-desk theme in this folder from the sticker generators in ../src/clawd_dev.py,
plus the theme-only animations in animations.py and svg.py.

  python build.py   # light and dark assets -> clawd-dev-life/

https://github.com/rullerzhou-afk/clawd-on-desk/blob/main/docs/guides/guide-theme-creation.md
"""
import json, os, sys
THEME_DIR=os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0,os.path.join(THEME_DIR,'..','src'))
from clawd_dev import *
from animations import ANIMATIONS
from mini import MINI_FRAMES, MINI_OFFSET, MINI_PEEK, MINI_STOPS, MINI_SVGS, MINI_TIMED, MINI_VIEWBOX
from svg import SVGS

WORKING=['todo','simple','bug','loop','deadline']
# viewBox is in body cells, the same grid as the built-in Clawd theme (body x 0..15, feet at y=15).
THEME={
 'states':{'idle':['idle'],'thinking':['thinking','ultrathink','plan'],'working':WORKING,
           'juggling':['subagents'],'sweeping':['compact'],'carrying':['clone'],'notification':['proceed'],
           'attention':['passed_long','lgtm'],'error':['error'],'sleeping':['sleep'],'roam':['roam'],
           'dizzy':['dizzy'],
           'yawning':['yawn'],'dozing':['sleep'],'collapsing':['sleep'],'waking':['wake']},
 'workingTiers':[(3,['team3']),(2,['team2','conflict']),(1,WORKING)],
 'idleAnimations':['fish','coffee','duck','works','blame','deploy','overtime','offwork','leak','overflow','cherry',
                   'esc','forcepush','stash','clear','bye_long'],
 'hitBoxes':{'conflict':{'x':-4,'y':5,'w':23,'h':11},'team2':{'x':-3,'y':2,'w':21,'h':14},'team3':{'x':-3,'y':-4,'w':21,'h':20}},   # wider than one Clawd
 'reactions':{'drag':'drag','clickLeft':'hello','clickRight':'right','annoyed':'notfound','double':['rmrf','detached_long','banned_long']},
}
ONESHOT=['attention','error','notification','carrying','dizzy']   # hold until the animation has played once
HOLD=300   # ms of extra stillness on the last frame of an animation played once for a fixed time
def to_apng(frames,path,plays=0):
    frames[0][0].save(path,format='PNG',save_all=True,append_images=[im for im,_ in frames[1:]],
                      duration=[d for _,d in frames],loop=plays,disposal=0,blend=0)
    return os.path.getsize(path)
def frames(nm): return square((ANIMATIONS.get(nm) or STICKERS[nm])())
def theme():
    out=os.path.join(THEME_DIR,'clawd-dev-life')
    names=list(dict.fromkeys(n for v in THEME['states'].values() for n in v))
    names+=[n for _,ns in THEME['workingTiers'] for n in ns]+THEME['idleAnimations']
    names+=[n for v in THEME['reactions'].values() for n in ([v] if isinstance(v,str) else v)]+list(MINI_FRAMES)
    vb={'x':-OX-(H-W)/2,'y':-OY,'width':H,'height':H}
    st=THEME['states']; first=lambda s:ms[st[s][0]]
    # Animations clawd-on-desk plays once for a fixed time. Each gets HOLD ms of extra stillness on its
    # last frame, so a timer firing a little late never shows the loop restart. A reaction or state pool
    # shares one duration, so its shorter members hold their last frame until the longest one ends.
    once=set(THEME['idleAnimations'])|{n for s in ONESHOT+['yawning','waking'] for n in st[s]}
    once|={n for k,v in THEME['reactions'].items() if k!='drag' for n in ([v] if isinstance(v,str) else v)}
    once|={*MINI_TIMED,*MINI_STOPS}
    pools=[v for v in THEME['reactions'].values() if not isinstance(v,str)]+[st[s] for s in ONESHOT if len(st[s])>1]
    durations={}; f=lambda n:n+('.svg' if n in SVGS or n in MINI_SVGS else '.apng')
    def write(nm,fr,pad=0):
        if nm in once: fr[-1]=(fr[-1][0],fr[-1][1]+pad+HOLD)
        n=to_apng(fr,os.path.join(ad,f(nm)),1 if nm in MINI_STOPS else 0)
        print(f'{nm}: {len(fr)} frames, {ms[nm]}ms'+(f' (+{pad}ms hold)' if pad else '')+f', {n//1024}KB')
    for dark in (False,True):
        set_dark(dark)
        ad=os.path.join(out,'assets-dark' if dark else 'assets'); os.makedirs(ad,exist_ok=True)
        for nm,fn in SVGS.items():
            with open(os.path.join(ad,nm+'.svg'),'w',encoding='utf-8') as fp: fp.write(fn(vb))
        for nm,fn in MINI_SVGS.items():
            with open(os.path.join(ad,nm+'.svg'),'w',encoding='utf-8') as fp: fp.write(fn(MINI_VIEWBOX))
        ms={}; pending={}
        for nm in dict.fromkeys(n for n in names if n not in SVGS):
            fr=(MINI_FRAMES.get(nm) or (lambda:frames(nm)))(); ds=[d for _,d in fr]
            # Both palettes share timers; compare before pool padding can hide a mismatch.
            if not dark: durations[nm]=ds
            elif ds!=durations[nm]: raise ValueError(f'{nm}: light and dark frame durations differ')
            ms[nm]=sum(ds)
            if any(nm in p for p in pools): pending[nm]=fr
            else: write(nm,fr)
        for p in pools:
            T=max(ms[n] for n in p)
            for n in p: pad=T-ms[n]; ms[n]=T; write(n,pending[n],pad)
    cfg={
     'schemaVersion':1,
     'name':'Clawd Dev Life',
     'author':'alwinecor','version':'1.2.0','license':'CC BY-NC-SA 4.0',
     'description':'Clawd Dev Life 主题：思考、写码、压缩上下文、报错都有对应的小剧场。'
                   '非官方同人作品，与 Anthropic 无关。',
     'preview':f('idle'),
     'appearance':{'dark':{'assetsDir':'assets-dark'}},
     'viewBox':vb,
     'layout':{'contentBox':{'x':0,'y':6,'width':15,'height':10},'centerX':7.5,'baselineY':16,
               'visibleHeightRatio':0.29,'baselineBottomRatio':0.05},
     # Same values as the built-in Clawd; the ratios place the eyes (7.5, 9) inside our viewBox.
     'eyeTracking':{'enabled':True,'states':['idle','mini-idle'],
                    'eyeRatioX':(7.5-vb['x'])/vb['width'],'eyeRatioY':round((9-vb['y'])/vb['height'],3),
                    'maxOffset':3,'bodyScale':0.33,'shadowStretch':0.15,'shadowShift':0.3,
                    'ids':{'eyes':'eyes-js','body':'body-js','shadow':'shadow-js'},'shadowOrigin':'7.5px 15px'},
     'customization':{'petTint':False},
     'states':{s:[f(n) for n in v] for s,v in st.items()},
     # yawning hands over to dozing/collapsing/sleeping, which all show Good Night: the yawn ends on its
     # first frame, and deepSleepTimeout/collapseDuration move on at once so the picture never changes.
     'sleepSequence':{'mode':'full'},
     'workingTiers':[{'minSessions':k,'file':f(ns[0]),**({'files':[f(n) for n in ns]} if len(ns)>1 else {})}
                     for k,ns in THEME['workingTiers']],
     'idleAnimations':[{'file':f(n),'duration':ms[n]} for n in THEME['idleAnimations']],
     'reactions':{k:({'file':f(v)} if k=='drag' else {'file':f(v),'duration':ms[v]} if isinstance(v,str) else
                     {'files':[f(n) for n in v],'duration':max(ms[n] for n in v)})
                  for k,v in THEME['reactions'].items()},
     'timings':{'minDisplay':{**{s:first(s) for s in ONESHOT},'sweeping':first('sweeping'),
                              'working':1000,'thinking':1000},
                'autoReturn':{**{s:first(s) for s in ONESHOT},'sweeping':300000},
                'mouseIdleTimeout':20000,'mouseSleepTimeout':60000,
                'yawnDuration':first('yawning'),'deepSleepTimeout':60000+first('yawning'),'collapseDuration':100,
                'wakeDuration':first('waking')},
     'hitBoxes':{'default':{'x':-1,'y':5,'w':17,'h':11}},
     'fileHitBoxes':{f(n):b for n,b in THEME['hitBoxes'].items()},
     'miniMode':{'supported':True,'offsetRatio':MINI_OFFSET,'peek':{'offsetRatio':MINI_PEEK},'viewBox':MINI_VIEWBOX,
                 'states':{n:[f(n)] for n in (*MINI_SVGS,*MINI_FRAMES)},
                 'timings':{'minDisplay':{s:ms[s] for s in MINI_TIMED},'autoReturn':{s:ms[s] for s in MINI_TIMED}}},
    }
    with open(os.path.join(out,'theme.json'),'w',encoding='utf-8') as fp:
        json.dump(cfg,fp,ensure_ascii=False,indent=2); fp.write('\n')
    # templates/ holds the documents shipped beside theme.json.
    for nm in ('LICENSE','README.md','README.zh-CN.md'):
        with open(os.path.join(THEME_DIR,'templates',nm),encoding='utf-8') as fp: text=fp.read()
        with open(os.path.join(out,nm),'w',encoding='utf-8') as fp:
            fp.write(text.replace('{name}',cfg['name']).replace('{version}',cfg['version']).replace('{id}',os.path.basename(out)))
    print(f'theme -> {os.path.normpath(out)}')

if __name__=='__main__':
    theme()
