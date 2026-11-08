"""Render the original vector mark. Requires Pillow; no model/image service."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]

def mark(size, background=True):
    scale = 4
    image = Image.new('RGB' if background else 'RGBA', (size*scale, size*scale), '#171717' if background else (0,0,0,0))
    d = ImageDraw.Draw(image)
    def xy(x,y): return ((152+x*15)*size*scale/1024,(128+y*15)*size*scale/1024)
    width=max(1, round(2.6*15*size*scale/1024))
    # Match the code-native app mark, including its folded page corner.
    points=[(12,7),(31,7),(39,15),(39,37),(38,40),(35,41),(12,41),(9,40),(8,37),(8,11),(9,8),(12,7)]
    for path in [points,[(30,8),(30,16),(38,16)],[(17,24),(17,30)],[(24,20),(24,34)],[(31,24),(31,30)]]:
        d.line([xy(x,y) for x,y in path], fill='white', width=width, joint='curve')
        for x,y in path:
            a,b=xy(x,y); r=width/2;d.ellipse((a-r,b-r,a+r,b+r),fill='white')
    return image.resize((size,size),Image.Resampling.LANCZOS)

assets=ROOT/'ios/Runner/Assets.xcassets/AppIcon.appiconset'
contents=json.loads((assets/'Contents.json').read_text())
for item in contents['images']:
    if 'filename' in item:
        size=round(float(item['size'].split('x')[0])*float(item.get('scale','1x')[:-1]))
        mark(size).save(assets/item['filename'])
for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    mark(size).save(ROOT/f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
# iOS shortcut templates are alpha masks, never application logos.
for name in ['shortcut_capture','shortcut_search']:
    folder=ROOT/'ios/Runner/Assets.xcassets'/f'{name}.imageset';folder.mkdir(exist_ok=True)
    images=[]
    for scale in [1,2,3]:
        n=35*scale; im=Image.new('RGBA',(n,n),(0,0,0,0));d=ImageDraw.Draw(im);w=2*scale
        if name.endswith('search'):
            d.ellipse((7*scale,5*scale,23*scale,21*scale),outline='white',width=w);d.line((21*scale,20*scale,29*scale,28*scale),fill='white',width=w)
        else:
            d.rounded_rectangle((13*scale,4*scale,23*scale,22*scale),radius=5*scale,outline='white',width=w)
            d.arc((8*scale,10*scale,28*scale,27*scale),0,180,fill='white',width=w);d.line((18*scale,26*scale,18*scale,31*scale),fill='white',width=w)
        filename=f'{name}@{scale}x.png';im.save(folder/filename);images.append(dict(idiom='universal',filename=filename,scale=f'{scale}x'))
    (folder/'Contents.json').write_text(json.dumps(dict(images=images,info=dict(author='xcode',version=1)),indent=2)+'\n')
mark(1024).save(ROOT/'assets/icons/nianxia.png')
