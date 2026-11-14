"""Renders the balancer part sprites with Blender, in Factorio's camera/lighting conventions.

    python graphics/source/balancer.py                    render DESIGN into graphics/
    python graphics/source/balancer.py --design gears     render another design into graphics/
    python graphics/source/balancer.py --drafts DIR [design ...]   quick animated previews (default: all)

Run with plain Python (needs Pillow): it runs Blender on this same file to render the raw images,
then assembles the sprite sheet, shadow and icons. Set BLENDER to use another Blender executable.
"""
import math
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(tempfile.gettempdir(), "belt-balancer-render")
GFX = os.path.dirname(HERE)

DESIGN = "tower-brackets"  # the one shipped in graphics/
DESIGNS = ["impeller", "gears", "turntables", "tower", "tower-brackets"]
FRAMES = 16
FRAME_PX = 112  # 1.75 tiles at 64 px/tile (scale 0.5)
DRAFT = os.environ.get("BB_QUALITY") == "draft"
SS = 2 if DRAFT else 4  # supersampling factor


# --------------------------------------------------------------------------------------------- Blender
def render():
    import bpy
    from mathutils import Vector

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    def srgb(r, g, b):
        f = lambda c: (c / 255) / 12.92 if c / 255 <= 0.04045 else ((c / 255 + 0.055) / 1.055) ** 2.4
        return (f(r), f(g), f(b), 1)

    # ---------------------------------------------------------------- materials
    def material(name, color, metallic, roughness, wear_color=None, wear=0.0, rust=0.0, stripes=None):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        n, l = nt.nodes, nt.links
        bsdf = n["Principled BSDF"]
        coord = n.new("ShaderNodeTexCoord")

        def noise(scale, detail=6.0, rough=0.6):
            t = n.new("ShaderNodeTexNoise")
            t.inputs["Scale"].default_value = scale
            t.inputs["Detail"].default_value = detail
            t.inputs["Roughness"].default_value = rough
            l.new(coord.outputs["Object"], t.inputs["Vector"])
            return t.outputs["Fac"]

        def ramp(src, a, b):
            r = n.new("ShaderNodeValToRGB")
            r.color_ramp.elements[0].position = a
            r.color_ramp.elements[1].position = b
            l.new(src, r.inputs["Fac"])
            return r.outputs["Color"]

        def mix(fac, a, b):
            mx = n.new("ShaderNodeMix")
            mx.data_type = "RGBA"
            l.new(fac, mx.inputs["Factor"])
            for i, v in ((6, a), (7, b)):
                if isinstance(v, tuple):
                    mx.inputs[i].default_value = v
                else:
                    l.new(v, mx.inputs[i])
            return mx.outputs[2]

        def math_node(op, a, b):
            mt = n.new("ShaderNodeMath")
            mt.operation = op
            for i, v in ((0, a), (1, b)):
                if isinstance(v, (int, float)):
                    mt.inputs[i].default_value = v
                else:
                    l.new(v, mt.inputs[i])
            return mt.outputs[0]

        base = color
        if stripes:  # diagonal hazard stripes, on any face
            sep = n.new("ShaderNodeSeparateXYZ")
            l.new(coord.outputs["Object"], sep.inputs[0])
            diag = math_node("ADD", math_node("ADD", sep.outputs[0], sep.outputs[1]), sep.outputs[2])
            band = math_node("GREATER_THAN", math_node("FRACT", math_node("MULTIPLY", diag, stripes), 0), 0.5)
            base = mix(band, color, srgb(28, 26, 24))

        # dirt: low-frequency blotches darken and brown the surface
        dirt = ramp(noise(9.0), 0.45, 0.75)
        base = mix(math_node("MULTIPLY", dirt, 0.55), base, srgb(52, 40, 28))
        if rust:
            rmask = ramp(noise(14.0, 10.0, 0.7), 0.62 - rust * 0.25, 0.70 - rust * 0.25)
            base = mix(rmask, base, srgb(104, 56, 30))

        # worn edges: compare a bevelled normal to the true normal
        metal_mask = None
        if wear:
            bev = n.new("ShaderNodeBevel")
            bev.inputs["Radius"].default_value = 0.008
            geo = n.new("ShaderNodeNewGeometry")
            dot = n.new("ShaderNodeVectorMath")
            dot.operation = "DOT_PRODUCT"
            l.new(bev.outputs["Normal"], dot.inputs[0])
            l.new(geo.outputs["Normal"], dot.inputs[1])
            edge = math_node("SUBTRACT", 1.0, dot.outputs["Value"])
            scratch = math_node("MULTIPLY", noise(60.0, 12.0, 0.75), wear * 0.35)
            m_raw = math_node("ADD", math_node("MULTIPLY", edge, 40.0 * wear), scratch)
            metal_mask = ramp(m_raw, 0.28, 0.32)
            base = mix(metal_mask, base, wear_color)

        # cavity darkening, strong like vanilla renders
        ao = n.new("ShaderNodeAmbientOcclusion")
        ao.inputs["Distance"].default_value = 0.06
        aof = ramp(ao.outputs["AO"], 0.0, 1.0)
        mul = n.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 0.85
        if isinstance(base, tuple):
            mul.inputs[6].default_value = base
        else:
            l.new(base, mul.inputs[6])
        l.new(aof, mul.inputs[7])
        l.new(mul.outputs[2], bsdf.inputs["Base Color"])

        if metal_mask is not None:
            mm = n.new("ShaderNodeMapRange")
            l.new(metal_mask, mm.inputs["Value"])
            mm.inputs["To Min"].default_value = metallic
            mm.inputs["To Max"].default_value = 0.9
            l.new(mm.outputs["Result"], bsdf.inputs["Metallic"])
        else:
            bsdf.inputs["Metallic"].default_value = metallic
        rr = n.new("ShaderNodeMapRange")
        l.new(noise(25.0), rr.inputs["Value"])
        rr.inputs["To Min"].default_value = roughness - 0.1
        rr.inputs["To Max"].default_value = roughness + 0.1
        l.new(rr.outputs["Result"], bsdf.inputs["Roughness"])
        return m

    steel_bare = srgb(150, 148, 142)
    yellow = material("yellow", srgb(212, 156, 36), 0.0, 0.5, steel_bare, wear=1.0)
    hazard = material("hazard", srgb(212, 156, 36), 0.0, 0.55, steel_bare, wear=0.8, stripes=14.0)
    frame = material("frame", srgb(78, 80, 84), 0.7, 0.55, steel_bare, wear=0.7, rust=0.35)
    dark = material("dark", srgb(30, 30, 32), 0.3, 0.7, rust=0.3)
    bright = material("bright", srgb(150, 154, 160), 0.9, 0.35, steel_bare, wear=0.5, rust=0.25)

    # ---------------------------------------------------------------- geometry helpers
    def finish(o, mat, bevel=0.0, segments=2, smooth_angle=40):
        bpy.context.view_layer.objects.active = o
        if bevel:
            b = o.modifiers.new("bevel", "BEVEL")
            b.width = bevel
            b.segments = segments
            b.limit_method = "ANGLE"
            bpy.ops.object.modifier_apply(modifier=b.name)
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(smooth_angle))
        o.data.materials.append(mat)
        return o

    def box(size, loc, mat, bevel=0.0, rot=(0, 0, 0)):
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
        o = bpy.context.object
        o.scale = size
        bpy.ops.object.transform_apply(scale=True)
        return finish(o, mat, bevel)

    def cyl(r, h, loc, mat, verts=64, bevel=0.0, rot=(0, 0, 0)):
        bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=h, location=loc, rotation=rot)
        return finish(bpy.context.object, mat, bevel)

    def ring(radius, tube, loc, mat):
        bpy.ops.mesh.primitive_torus_add(major_radius=radius, minor_radius=tube, location=loc,
                                         major_segments=96, minor_segments=12)
        return finish(bpy.context.object, mat)

    def prism(points, z0, z1, mat, bevel=0.0):
        """Extrude a 2D outline (counter-clockwise) between two heights."""
        k = len(points)
        verts = [(x, y, z0) for x, y in points] + [(x, y, z1) for x, y in points]
        faces = [list(range(k))[::-1], list(range(k, 2 * k))]
        faces += [[i, (i + 1) % k, k + (i + 1) % k, k + i] for i in range(k)]
        mesh = bpy.data.meshes.new("prism")
        mesh.from_pydata(verts, [], faces)
        o = bpy.data.objects.new("prism", mesh)
        scene.collection.objects.link(o)
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        return finish(o, mat, bevel)

    def cut(target, cutter):
        bpy.context.view_layer.objects.active = target
        m = target.modifiers.new("cut", "BOOLEAN")
        m.object = cutter
        m.operation = "DIFFERENCE"
        bpy.ops.object.modifier_apply(modifier=m.name)
        bpy.data.objects.remove(cutter)

    def tmp_box(size, loc):
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
        o = bpy.context.object
        o.scale = size
        return o

    def tmp_cyl(r, h, loc):
        bpy.ops.mesh.primitive_cylinder_add(vertices=96, radius=r, depth=h, location=loc)
        return bpy.context.object

    def pivot(x=0.0, y=0.0):
        bpy.ops.object.empty_add(location=(x, y, 0))
        return bpy.context.object

    def attach(parts, parent):
        for p in parts:
            p.parent = parent
            p.location.x -= parent.location.x
            p.location.y -= parent.location.y
        return parts

    def housing(height, out):
        """Skid + steel box with belt openings on all four sides and rollers inside them."""
        out.append(box((0.92, 0.92, 0.04), (0, 0, 0.02), frame, 0.01))
        body = box((0.84, 0.84, height - 0.04), (0, 0, 0.04 + (height - 0.04) / 2), frame, 0.02)
        for ang in range(4):
            a = math.radians(90 * ang)
            c = tmp_box((0.56, 0.2, 0.085), (0.42 * math.sin(a), -0.42 * math.cos(a), 0.11))
            c.rotation_euler.z = a
            cut(body, c)
        for ang in range(4):
            a = math.radians(90 * ang)
            out.append(cyl(0.022, 0.54, (0.36 * math.sin(a), -0.36 * math.cos(a), 0.09), bright, 24,
                           rot=(0, math.radians(90), a)))
            out.append(box((0.54, 0.12, 0.02), (0.33 * math.sin(a), -0.33 * math.cos(a), 0.075), dark,
                           rot=(0, 0, a)))
        return body

    def corner_bolts(z, out, d=0.385):
        for sx in (-1, 1):
            for sy in (-1, 1):
                out.append(cyl(0.02, 0.014, (d * sx, d * sy, z), bright, 6, 0.003))

    def corner_brackets(z, out, d=0.395):
        """Bolted yellow L-brackets on the four corners of a deck whose top is at z."""
        for sx in (-1, 1):
            for sy in (-1, 1):
                out.append(box((0.24, 0.07, 0.022), (sx * (d - 0.085), sy * d, z + 0.011), yellow, 0.006))
                out.append(box((0.07, 0.17, 0.022), (sx * d, sy * (d - 0.12), z + 0.011), yellow, 0.006))
                out.append(cyl(0.014, 0.012, (sx * (d - 0.135), sy * d, z + 0.024), bright, 6, 0.002))
        corner_bolts(z + 0.026, out, d - 0.01)

    def gear(teeth, radius, x, y, z, thick, mat):
        """Spur gear centred on (x, y). Every detail repeats per tooth, so it loops per tooth."""
        parts = [cyl(radius, thick, (x, y, z), mat, 96, 0.004)]
        for i in range(teeth):
            a = 2 * math.pi * (i + 0.5) / teeth
            parts.append(box((0.035, 0.028, thick), (x + (radius + 0.012) * math.cos(a), y + (radius + 0.012) * math.sin(a), z),
                             mat, 0.003, rot=(0, 0, a)))
        parts.append(cyl(radius * 0.45, thick + 0.01, (x, y, z + 0.005), dark, 48, 0.003))
        for i in range(teeth):
            a = 2 * math.pi * i / teeth
            parts.append(cyl(radius * 0.07, thick + 0.012, (x + radius * 0.72 * math.cos(a), y + radius * 0.72 * math.sin(a), z),
                             dark, 12))
        return parts

    def impeller(z0=0.0, vanes=8):
        """Geared turntable with vanes. Returns (parts, angle turned per loop)."""
        parts = [cyl(0.27, 0.03, (0, 0, z0 + 0.11), bright, 96, 0.004)]
        for i in range(vanes * 4):
            a = 2 * math.pi * (i + 0.5) / (vanes * 4)
            parts.append(box((0.03, 0.024, 0.03), (0.283 * math.cos(a), 0.283 * math.sin(a), z0 + 0.11),
                             frame, 0.003, rot=(0, 0, a)))
        for i in range(vanes):
            a = 2 * math.pi * i / vanes
            parts.append(box((0.17, 0.042, 0.09), (0.175 * math.cos(a), 0.175 * math.sin(a), z0 + 0.17), bright, 0.008,
                             rot=(0, 0, a + math.radians(20))))
        parts.append(cyl(0.085, 0.12, (0, 0, z0 + 0.185), yellow, 64, 0.012))
        parts.append(cyl(0.04, 0.02, (0, 0, z0 + 0.25), dark, 32, 0.004))
        for i in range(vanes):  # every rotating detail needs vanes-fold symmetry or the loop visibly jumps
            a = 2 * math.pi * (i + 0.5) / vanes
            parts.append(cyl(0.012, 0.012, (0.062 * math.cos(a), 0.062 * math.sin(a), z0 + 0.248), bright, 6))
        return parts, 2 * math.pi / vanes

    # ---------------------------------------------------------------- designs
    # Each returns (all objects, [(pivot, angle it turns per animation loop)]).
    def design_impeller():
        """Low housing, yellow corner brackets, impeller in a round well."""
        out = []
        body = housing(0.24, out)
        cut(body, tmp_cyl(0.31, 0.3, (0, 0, 0.27)))
        out.append(body)
        out.append(box((0.64, 0.012, 0.07), (0, -0.421, 0.19), hazard, 0.003))
        for k in range(7):
            out.append(cyl(0.012, 0.01, (-0.33 + k * 0.11, -0.421, 0.045), bright, 8, rot=(math.radians(90), 0, 0)))
        deck = box((0.86, 0.86, 0.03), (0, 0, 0.255), frame, 0.01)
        cut(deck, tmp_cyl(0.32, 0.2, (0, 0, 0.26)))
        out.append(deck)
        corner_brackets(0.27, out)
        out.append(ring(0.325, 0.016, (0, 0, 0.272), bright))
        out.append(cyl(0.31, 0.02, (0, 0, 0.06), dark))
        parts, loop = impeller()
        return out + attach(parts, pivot()), [(parts[0].parent, loop)]

    def design_gears():
        """Yellow chevrons on all four edges point at an open gear train: one big gear driving four small ones."""
        out = []
        body = housing(0.24, out)
        cut(body, tmp_box((0.62, 0.62, 0.3), (0, 0, 0.27)))
        out.append(body)
        deck = box((0.86, 0.86, 0.03), (0, 0, 0.255), frame, 0.01)
        cut(deck, tmp_box((0.62, 0.62, 0.2), (0, 0, 0.26)))
        out.append(deck)
        out.append(box((0.6, 0.6, 0.02), (0, 0, 0.16), dark))
        chevron = [(-0.22, 0.0), (0.0, 0.07), (0.22, 0.0), (0.22, 0.05), (0.0, 0.12), (-0.22, 0.05)]
        for ang in range(4):  # chevrons point inwards, like the splitter's yellow covers
            a = math.radians(90 * ang)
            pts = [((x) * math.cos(a) - (y - 0.43) * math.sin(a), (x) * math.sin(a) + (y - 0.43) * math.cos(a))
                   for x, y in chevron]
            out.append(prism(pts, 0.27, 0.292, yellow, 0.005))
        corner_bolts(0.285, out)
        out.append(box((0.62, 0.012, 0.06), (0, -0.421, 0.19), hazard, 0.003))
        rot = []
        big = pivot()
        out += attach(gear(16, 0.14, 0, 0, 0.215, 0.05, bright), big)
        rot.append((big, 2 * math.pi / 16))
        for k in range(4):  # small gears mesh at the diagonals and turn twice as fast the other way
            a = math.radians(45 + 90 * k)
            x, y = 0.228 * math.cos(a), 0.228 * math.sin(a)
            p = pivot(x, y)
            out += attach(gear(8, 0.066, x, y, 0.205, 0.045, yellow), p)
            p.rotation_euler.z = math.pi / 8 + a  # offset so the teeth interleave
            rot.append((p, -2 * math.pi / 8))
        return out, rot

    def design_turntables():
        """Low platform with a hazard-striped rim and four counter-rotating turntables."""
        out = []
        out.append(housing(0.2, out))
        out.append(box((0.86, 0.86, 0.03), (0, 0, 0.215), hazard, 0.008))
        out.append(box((0.77, 0.77, 0.034), (0, 0, 0.216), frame, 0.006))
        corner_bolts(0.24, out, 0.405)
        rot = []
        for k, (x, y) in enumerate(((0.17, 0.17), (-0.17, 0.17), (-0.17, -0.17), (0.17, -0.17))):
            out.append(ring(0.145, 0.012, (x, y, 0.236), bright))
            p = pivot(x, y)
            parts = [cyl(0.135, 0.02, (x, y, 0.236), dark, 64)]
            for i in range(4):
                a = math.pi / 2 * i
                parts.append(box((0.11, 0.032, 0.026), (x + 0.065 * math.cos(a), y + 0.065 * math.sin(a), 0.252), bright,
                                 0.006, rot=(0, 0, a)))
            parts.append(cyl(0.038, 0.036, (x, y, 0.258), yellow, 32, 0.008))
            out += attach(parts, p)
            rot.append((p, (math.pi / 2) * (1 if k % 2 == 0 else -1)))
        return out, rot

    def design_tower(brackets=False):
        """Taller ribbed housing with a hazard band and a grated top over the impeller."""
        out = []
        body = housing(0.42, out)
        cut(body, tmp_cyl(0.3, 0.4, (0, 0, 0.5)))
        out.append(body)
        band = box((0.86, 0.86, 0.06), (0, 0, 0.33), hazard, 0.008)
        cut(band, tmp_cyl(0.3, 0.4, (0, 0, 0.5)))
        out.append(band)
        for k in range(5):  # ribs on the front
            out.append(box((0.04, 0.03, 0.12), (-0.28 + k * 0.14, -0.425, 0.225), frame, 0.008))
        deck = box((0.84, 0.84, 0.03), (0, 0, 0.415), frame, 0.012)
        cut(deck, tmp_cyl(0.3, 0.2, (0, 0, 0.42)))
        out.append(deck)
        out.append(ring(0.305, 0.018, (0, 0, 0.43), bright))
        for k in range(-4, 5):  # grating
            w = 2 * math.sqrt(max(0.0, 0.3 ** 2 - (k * 0.065) ** 2))
            if w > 0.05:
                out.append(box((w, 0.012, 0.02), (0, k * 0.065, 0.42), frame))
        if brackets:
            corner_brackets(0.43, out, 0.385)
        else:
            corner_bolts(0.44, out, 0.37)
        out.append(cyl(0.29, 0.02, (0, 0, 0.12), dark))
        parts, loop = impeller(0.13)
        return out + attach(parts, pivot()), [(parts[0].parent, loop)]

    design = os.environ.get("BB_DESIGN", DESIGN)
    model, rotors = {"impeller": design_impeller, "gears": design_gears, "turntables": design_turntables,
                     "tower": design_tower, "tower-brackets": lambda: design_tower(brackets=True)}[design]()
    start = {e: e.rotation_euler.z for e, _ in rotors}

    # ---------------------------------------------------------------- camera, light, render settings
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (0, -10, 10)
    cam.rotation_euler = (math.radians(45), 0, 0)  # Factorio's view: orthographic, 45 degrees from above
    scene.camera = cam

    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 4.5
    sun_data.angle = math.radians(2)
    sun = bpy.data.objects.new("sun", sun_data)
    scene.collection.objects.link(sun)
    # light from the upper left (north-west), shadow falls to the east and slightly south
    sun.rotation_euler = Vector((1.0, -0.35, -0.95)).to_track_quat("-Z", "Y").to_euler()

    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.42, 0.44, 0.48, 1)
    bg.inputs["Strength"].default_value = 1.0
    scene.world = world

    scene.render.engine = "CYCLES"
    scene.cycles.samples = 32 if DRAFT else 128
    scene.cycles.use_denoising = True
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "Medium High Contrast"
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    os.makedirs(RAW, exist_ok=True)

    def shoot(name, px, ortho, shift_y=0.0):
        scene.render.resolution_x = scene.render.resolution_y = px
        cam_data.ortho_scale = ortho
        cam_data.shift_y = shift_y
        scene.render.filepath = os.path.join(RAW, name)
        bpy.ops.render.render(write_still=True)

    def pose(f):
        for e, loop in rotors:
            e.rotation_euler.z = start[e] - loop * f / FRAMES

    # entity frames: a 1-tile footprint is 64 px wide
    for f in range(FRAMES):
        pose(f)
        shoot("frame_%02d.png" % f, FRAME_PX * SS, FRAME_PX / 64)
    # icon: framed loosely, cropped to the model afterwards
    pose(0)
    shoot("icon.png", 256 * SS, 1.4, 0.1)

    # shadow: model hidden from the camera but still casting onto a catcher, sun only
    bg.inputs["Strength"].default_value = 0
    for o in model:
        o.visible_camera = False
    bpy.ops.mesh.primitive_plane_add(size=6)
    bpy.context.object.is_shadow_catcher = True
    shoot("shadow.png", FRAME_PX * SS, FRAME_PX / 64)


# --------------------------------------------------------------------------------------------- assembly
def run_blender(design, quality):
    blender = os.environ.get("BLENDER", r"C:\Program Files\Blender Foundation\Blender 4.4\blender.exe")
    env = dict(os.environ, BB_DESIGN=design, BB_QUALITY=quality)
    subprocess.run([blender, "-b", "--factory-startup", "--python", os.path.abspath(__file__)], check=True, env=env,
                   stdout=subprocess.DEVNULL)


def down(img, size):
    from PIL import Image
    # premultiplied downscale, so edges don't pick up the transparent background's colour
    return img.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def load_frames():
    from PIL import Image
    frames = [down(Image.open(os.path.join(RAW, "frame_%02d.png" % f)), (FRAME_PX, FRAME_PX)) for f in range(FRAMES)]
    shadow = down(Image.open(os.path.join(RAW, "shadow.png")), (FRAME_PX, FRAME_PX))
    black = Image.new("L", shadow.size, 0)
    shadow = Image.merge("RGBA", (black, black, black, shadow.getchannel("A")))
    icon = Image.open(os.path.join(RAW, "icon.png"))
    icon = icon.crop(icon.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox())
    side = max(icon.size)
    square = Image.new("RGBA", (side, side))
    square.paste(icon, ((side - icon.width) // 2, (side - icon.height) // 2))
    return frames, shadow, square


def sized(square, size, margin):
    from PIL import Image
    out = Image.new("RGBA", (size, size))
    out.alpha_composite(down(square, (size - 2 * margin, size - 2 * margin)), (margin, margin))
    return out


def build(design):
    from PIL import Image
    run_blender(design, "final")
    frames, shadow, square = load_frames()
    sheet = Image.new("RGBA", (FRAME_PX * 8, FRAME_PX * (FRAMES // 8)))
    for f, frame in enumerate(frames):
        sheet.paste(frame, ((f % 8) * FRAME_PX, (f // 8) * FRAME_PX))
    sheet.save(os.path.join(GFX, "entities", "balancer.png"), optimize=True)
    shadow.save(os.path.join(GFX, "entities", "balancer-shadow.png"), optimize=True)
    os.makedirs(os.path.join(GFX, "technology"), exist_ok=True)
    sized(square, 64, 2).save(os.path.join(GFX, "icons", "balancer.png"), optimize=True)
    sized(square, 256, 16).save(os.path.join(GFX, "technology", "balancer.png"), optimize=True)
    sized(square, 144, 8).save(os.path.join(GFX, "..", "thumbnail.png"), optimize=True)


def drafts(out_dir, designs):
    """Designs on in-game-like ground: an animated GIF each, plus one side-by-side still."""
    from PIL import Image, ImageDraw
    os.makedirs(out_dir, exist_ok=True)
    ground, line, zoom = (72, 64, 52, 255), (62, 55, 45, 255), 3

    def scene_img(frames_with_shadow, icon):
        img = Image.new("RGBA", (FRAME_PX * 2 + 20, FRAME_PX), ground)
        d = ImageDraw.Draw(img)
        for x in range(24, img.width, 64):
            d.line([(x, 0), (x, img.height)], fill=line)
        for y in range(24, img.height, 64):
            d.line([(0, y), (img.width, y)], fill=line)
        frame, shadow = frames_with_shadow
        for cx in (0, 64):  # two parts side by side, as they'd be built
            shade = shadow.copy()
            shade.putalpha(shadow.getchannel("A").point(lambda v: int(v * 0.55)))
            img.alpha_composite(shade, (cx, 0))
        for cx in (0, 64):
            img.alpha_composite(frame, (cx, 0))
        img.alpha_composite(icon, (img.width - 64 - 4, img.height - 64 - 4))
        return img.resize((img.width * zoom, img.height * zoom), Image.NEAREST)

    stills = []
    for design in designs:
        run_blender(design, "draft")
        frames, shadow, square = load_frames()
        icon = sized(square, 64, 2)
        anim = [scene_img((f, shadow), icon).convert("RGB") for f in frames]
        anim[0].save(os.path.join(out_dir, design + ".gif"), save_all=True, append_images=anim[1:],
                     duration=int(1000 / 60 / 0.15), loop=0)  # animation_speed 0.15 at 60 UPS
        stills.append((design, anim[0]))
    w, h = stills[0][1].size
    cols = 3 if len(stills) == 3 else 2
    sheet = Image.new("RGB", (w * cols, (h + 30) * ((len(stills) + cols - 1) // cols)), (40, 36, 30))
    d = ImageDraw.Draw(sheet)
    for i, (design, img) in enumerate(stills):
        x, y = (i % cols) * w, (i // cols) * (h + 30)
        sheet.paste(img, (x, y + 30))
        d.text((x + 10, y + 8), "%d. %s" % (i + 1, design), fill=(230, 220, 200))
    sheet.save(os.path.join(out_dir, "-vs-".join(designs) + ".png"))


if __name__ == "__main__":
    try:
        import bpy  # noqa: F401
        render()
    except ImportError:
        args = sys.argv[1:]
        if args[:1] == ["--drafts"]:
            drafts(args[1], args[2:] or DESIGNS)
        else:
            build(args[1] if args[:1] == ["--design"] else DESIGN)
