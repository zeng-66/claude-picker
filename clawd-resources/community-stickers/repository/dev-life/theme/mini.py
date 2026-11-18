# SPDX-License-Identifier: MIT
# License: ../../LICENSE; the drawn SVGs are artwork, see ../../LICENSE-ART and ../../NOTICE.md
"""
Mini mode of the clawd-on-desk theme: its own story, not shrunken stickers. The screen edge is the cubicle wall
and Clawd hides behind it. Nothing here has text, because the left screen edge mirrors every mini animation.

Drawn for the right edge, on a canvas of 45x45 body cells like the built-in Clawd's. The edge falls at x=8 at
rest and x=12 while peeking, so everything Clawd shows lives left of that.
"""
import math
from clawd_dev import *
from svg import LID, svg_doc, svg_eyes, svg_legs, svg_rect

MINI_VIEWBOX={'x':-15,'y':-25,'width':45,'height':45}
MINI_OFFSET=0.486   # share of the window behind the edge
MINI_PEEK=0.09      # share of the window a hover slides out: 4 cells
SIDE=45*S
GROUND=15           # last row the feet may reach
FLAG='#2FB15A'; FLAG_HI='#58CC7E'; POLE='#9A9AA6'; GLOW='#8FD8FF'; LID_GREY='#6A6A7A'; DUST='#CFC8C0'; PHONES='#6B7386'; PHONES_HI='#98A0B2'

def frame(*layers):
    out=Image.new('RGBA',(SIDE,SIDE),(0,0,0,0))
    for L in layers:
        if L is None: continue
        if isinstance(L,tuple): L=stamp(*L)
        out.alpha_composite(L)
    return out
def stamp(p,dx=0,dy=0):
    """Draws body cells shifted by (dx,dy) cells, which may be fractions: the art moves by whole pixels."""
    img=Image.new('RGBA',(SIDE,SIDE),(0,0,0,0)); d=ImageDraw.Draw(img)
    ox,oy=round((15+dx)*S),round((25+dy)*S)
    for (x,y),c in p.items():
        if y+dy>=GROUND+1: continue   # the floor hides what sinks through it
        X,Y=x*S+ox,y*S+oy
        d.rectangle([X,Y,X+S-1,Y+S-1],fill=tc(c))
    return img
def clawd(mode='n',dx=0,ey=0,blink=False,left=DOWN):   # the defaults are the Lookout pose
    p=base(); face(p,mode,dx,ey,blink); arms(p,left,DOWN); return p
def drop(x,y): return {(x,y):SWEAT,(x,y+1):SWEAT}
def disc(cx_,cy_,r,c):
    return {(x,y):c for x in range(cx_-r,cx_+r+1) for y in range(cy_-r,cy_+r+1) if (x-cx_)**2+(y-cy_)**2<=r*r+r/2}

# ---------- 望风 · Lookout (mini-idle) ----------
# Eye tracking moves #eyes-js and #body-js, so Clawd keeps an eye on the mouse. About every 30 seconds it has a
# good stretch, arms up. Breathes on the same clock as the full-size idle.
def mini_idle_svg(vb):
    r=svg_rect
    return svg_doc(vb,LID+"""      .stretch { transform-origin: 7.5px 15px; animation: stretch 30s infinite; }
      .arm { animation: arm 30s infinite step-end; }
      .breath { transform-origin: 7.5px 15px; animation: breath 2.7s infinite ease-in-out; }
      #eyes-js, #body-js { transition: transform 0.25s ease; }
      @keyframes stretch {
        0%, 88%, 100% { transform: none; animation-timing-function: ease-out; }
        90%, 94% { transform: scaleY(1.08); animation-timing-function: ease-in-out; }
        96% { transform: none; }
      }
      @keyframes arm { 0% { transform: none; } 89.5% { transform: translateY(-2px); } 95% { transform: none; } }
      @keyframes breath { 0%, 100% { transform: scaleY(1); } 50% { transform: scaleY(0.965); } }
""",f'''  <g fill="{BODY}">{svg_legs()}</g>
  <g class="stretch">
    <g id="body-js">
      <g class="breath" fill="{BODY}">
        {r(2,6,11,7)}<g class="arm">{r(0,9,2,2)}{r(13,9,2,2)}</g>
        <g id="eyes-js" fill="{K}">{svg_eyes(4,10)}</g>
      </g>
    </g>
  </g>
''')

# ---------- 溜号 · Slip Away (mini-crabwalk) ----------
# Off to slack, happily: a bouncy trot with a grin, arms swinging and little puffs of dust behind. Runs right;
# clawd-on-desk mirrors it for the left edge.
def mini_crabwalk_svg(vb):
    r=svg_rect
    grin=''.join(r(x,y,1,1) for ex in (5,11) for x,y in [(ex-1,9),(ex,8),(ex+1,9)])
    return svg_doc(vb,"""      .bounce { animation: bounce 0.36s infinite; }
      .step-a, .step-b { animation: step 0.72s infinite step-end; }
      .step-b { animation-delay: -0.36s; }
      .puff-a, .puff-b { animation: puff 0.72s infinite ease-out; }
      .puff-b { animation-delay: -0.36s; }
      @keyframes bounce {
        0%, 100% { transform: none; animation-timing-function: ease-out; }
        50% { transform: translate(0, -1px); animation-timing-function: ease-in; }
      }
      @keyframes step { 0% { transform: translate(0, -1px); } 50% { transform: none; } }
      @keyframes puff { 0% { transform: none; opacity: 0.9; } 100% { transform: translate(-3px, -1px); opacity: 0; } }
""",f'''  <g fill="{tc(DUST)}"><g class="puff-a">{r(1,14,1,1)}</g><g class="puff-b">{r(0,13,1,1)}</g></g>
  <g class="bounce" fill="{BODY}">
    {svg_legs(('step-a','step-b','step-a','step-b'))}
    {r(2,6,11,7)}<g class="step-a">{r(0,9,2,2)}</g><g class="step-b">{r(13,9,2,2)}</g>
    <g fill="{K}">{grin}</g>
  </g>
''')

# ---------- 躲好 · Hide (mini-enter) ----------
def mini_enter():
    """Whooshes behind the wall, stays out of sight for a beat, then creeps out in one unbroken move, landing on
    the Lookout pose. The whoosh comes first because after a walk from the
    menu clawd-on-desk keeps the window off screen for the first 300 ms."""
    fr=[]; N=29
    for i in range(N):
        sx=kf(i,[(0,0),(3,14),(7,14),(8,8.5),(28,0)])
        mode='x' if i<3 else 'n'
        fx={}
        if i<4:   # dust left behind by the whoosh
            for k,(x,y) in enumerate([(-1,7),(-2,10),(0,12),(-3,13)]):
                if k%2==i%2: fx[(x+i,y)]=DUST
        fr.append((frame((clawd(mode,-1 if 8<=i<27 else 0,blink=i==23),sx),(fx,)),70))
    hold(fr,{-1:200})
    return fr

# ---------- 被抓包 · Caught (mini-peek) ----------
def mini_peek():
    """Jumps in fright as the window slides out, a drop of sweat flying off, then lands on an awkward smile with a
    hand half raised, the first pose of Say Hi's wave."""
    fr=[]; N=12   # only a beat on the landing pose, so Say Hi picks up the wave at once
    for i in range(N):
        hop=2.4*math.sin(math.pi*clamp(i/6))
        p=clawd('x',left=UP) if i<9 else clawd('hap',left=MID)
        fr.append((frame((p,0,-hop),(drop(-2-i//2,4+i//2) if i<8 else {},)),60))
    return fr

# ---------- 打招呼 · Say Hi (mini-peek-hold) ----------
def mini_peek_hold():
    """Waves hello for as long as the mouse stays: the wave of hello, world, on the arm facing
    the desktop."""
    return [(frame((clawd('hap',left=UP if (i//3)%2 else MID),),),70) for i in range(24)]

# ---------- 偷偷干活 · Working in Secret (mini-working) ----------
LAPTOP={**{(x,14):POLE for x in range(-6,1)},**{(x,15):LID_GREY for x in range(-7,2)},
        **{p:LID_GREY for p in [(-6,13),(-6,12),(-7,11),(-7,10),(-8,9),(-8,8),(-7,13),(-7,12),(-8,11),(-8,10)]}}
def glow(flick):
    """The screen's light: a wedge in front of the lid and on Clawd's side, flickering as lines scroll."""
    col=GLOW if flick else mix(GLOW,'#FFFFFF',0.5)
    return {(x,y):col for x,y in [(-5,12),(-5,11),(-6,11),(-6,10),(-7,9),(-5,10),(-4,12)]}
def mini_working():
    """Crouched in the corner with a laptop, typing fast, and stopping now and then to check nobody is coming."""
    fr=[]; N=64
    for i in range(N):
        look=44<=i<54
        p=clawd('n',-1,-1 if look else 0,blink=i%28==6)
        if not look: arms(p,DOWN if (i//2)%2 else MID,DOWN)
        lit=(i//3)%3!=0
        for y in range(6,13):
            if (2,y) in p: p[(2,y)]=mix(BODY,GLOW,0.45 if lit else 0.25)
        fx={}
        if not look and i%3==0: fx[(-3+(i//3)%3,12)]=GLOW
        fr.append((frame((p,0,2),(LAPTOP,),(glow(lit),),(fx,)),70))
    return fr

# ---------- 有人找 · Someone's Asking (mini-alert) ----------
def mini_alert():
    """Leans out and waves under a red unread badge, then slips back."""
    fr=[]; N=56
    for i in range(N):
        out=kf(i,[(0,0),(4,-4),(50,-4),(55,0)])
        r=[0,1,2,3,4,3][i] if i<6 else 3
        bob=round(1.5*math.sin(TAU*i/10)) if 6<=i<50 else 0
        p=clawd('n',-1 if i<50 else 0,left=(UP if (i//2)%2 else MID) if 4<=i<50 else DOWN)
        badge=disc(-4,0+bob,r,RED) if 1<=i<52 else {}
        if r>=3 and badge: badge[(-5,-1+bob)]=WH; badge[(-4,-2+bob)]=WH
        fr.append((frame((p,out),(badge,)),70))
    return fr

# ---------- 亮绿旗 · Green Flag (mini-happy) ----------
def green_flag(i,top,width):
    """A pole growing out of the raised hand, with `top` as its top row, and a flag unfurling `width` cells off it."""
    p={(0,y):POLE for y in range(top,8)}
    for x in range(-width,0):
        sway=round(math.sin(TAU*(i/10+x/6)))
        for y in range(top,top+5):
            p[(x,y+sway)]=FLAG_HI if y==top+1 and x%2 else FLAG
    return p
def mini_happy():
    """CI is green: a little green flag shoots up from the hand and shakes above the wall, then tucks away."""
    fr=[]; N=52
    for i in range(N):
        top=round(kf(i,[(1,8),(5,-1),(46,-1),(50,8)]))
        width=round(kf(i,[(4,0),(9,6),(42,6),(47,0)]))   # 6 cells: leaning out 3, the flag ends at -9, inside the window
        hop=abs(math.sin(TAU*i/14))*1.2 if 8<=i<42 else 0
        out=kf(i,[(0,0),(4,-3),(46,-3),(51,0)])
        fr.append((frame((green_flag(i,top,width),out,-hop),(clawd('hap' if 4<=i<48 else 'n',left=UP if 2<=i<49 else DOWN),out,-hop)),70))
    return fr

# ---------- 戴耳机 · Headphones On (mini-enter-sleep), 午休 · Nap (mini-sleep), 偷看 · Who's There (mini-sleep-peek) ----------
# Noise-cancelling headphones are the sign that says do not disturb, so nothing needs hanging on the wall.
def cup(p,x0,dy=0):
    for x in range(x0,x0+3):
        for y in range(7,11): p[(x,y+dy)]=PHONES
    for y in (8,9): p[(x0+2 if x0<7 else x0,y+dy)]=PHONES_HI
def headphones(p,dy=0,lift=0,led=None):
    """Worn on the head, or `dy` rows lower; `lift` raises the ear cup facing the desktop. `led` lights that cup."""
    for x in range(2,13): p[(x,5+dy)]=PHONES
    p[(1,6+dy)]=PHONES; p[(13,6+dy)]=PHONES
    cup(p,0,dy-lift); cup(p,12,dy)
    if led: p[(1,9+dy-lift)]=led
    return p
def pulse(t): return mix(FLAG,'#14632F',0.5-0.5*math.cos(TAU*t))
def mini_enter_sleep():
    """Pulls the headphones up from around its neck, shuts its eyes as the light comes on, flops and lands on
    frame 0 of Nap."""
    fr=[]; N=30
    for i in range(N):
        on=i>=15
        p=clawd('n',-1,blink=on,left=UP if i<15 else DOWN)
        headphones(p,round(kf(i,[(3,6),(13,0)])),led=pulse(0) if on else None)
        k=clamp((i-16)/9)
        fr.append((frame((p,k,2*k)),70))
    return fr
def mini_sleep():
    """Slumped against the wall, slowly sagging until a little jolt pulls Clawd back up, the light breathing."""
    fr=[]; N=80
    for i in range(N):
        slip=kf(i,[(0,0),(60,1),(68,1),(72,0)])
        fr.append((frame((headphones(clawd('n',-1,blink=True),led=pulse(i/40)),1,2+slip)),90))
    return fr
def mini_sleep_peek():
    """A hover wakes Clawd just enough to hold an ear cup up and stare at whoever it is, blinking once."""
    fr=[]; N=24
    for i in range(N):
        lift=round(kf(i,[(1,0),(5,3)]))
        p=clawd('n',-1,blink=lift<2 or i==15,left=UP if lift else DOWN)
        fr.append((frame((headphones(p,lift=lift,led=None if lift else pulse(0)),1,2)),70))
    return fr

MINI_SVGS={'mini-idle':mini_idle_svg,'mini-crabwalk':mini_crabwalk_svg}
# How each drawn state ends. LOOP plays for as long as the state lasts. The other two are played once for a fixed
# time, like the full theme's, and get the hold on their last frame:
#   TIMED  the file loops like the full theme's and a timer ends it before the hold; the state reports its own
#          length in the theme's timings.
#   STOPS  no timer does that, so the file itself stops on its last frame: an entry ends after the whole file,
#          hold included, and Who's There lasts while the mouse stays.
LOOP,TIMED,STOPS='loop','timed','stops'
MINI={'mini-enter':(mini_enter,STOPS),'mini-enter-sleep':(mini_enter_sleep,STOPS),'mini-peek':(mini_peek,TIMED),
      'mini-peek-hold':(mini_peek_hold,LOOP),'mini-working':(mini_working,LOOP),'mini-alert':(mini_alert,TIMED),
      'mini-happy':(mini_happy,TIMED),'mini-sleep':(mini_sleep,LOOP),'mini-sleep-peek':(mini_sleep_peek,STOPS)}
MINI_FRAMES={n:fn for n,(fn,_) in MINI.items()}
MINI_TIMED=[n for n,(_,k) in MINI.items() if k==TIMED]
MINI_STOPS=[n for n,(_,k) in MINI.items() if k==STOPS]
