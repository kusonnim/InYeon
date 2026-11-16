from io import BytesIO

from PIL import Image, ImageOps

from app.storage import IMAGE_FORMATS


# Keep all inline bytes, plus base64 and JSON overhead, within the provider's request limit.
MAX_INLINE_IMAGE_BYTES = 12 * 1024 * 1024
MAX_RESIZED_SIDE = 4096


def prepare_model_image(
    media_type: str, data: bytes, byte_budget: int,
) -> tuple[tuple[str, bytes], tuple[str, ...]]:
    """Use the verified original when it fits, or derive a bounded image for the model."""
    with Image.open(BytesIO(data), formats=[IMAGE_FORMATS[media_type]]) as original:
        animated = getattr(original, "n_frames", 1) > 1
        if not animated and len(data) <= byte_budget:
            return (media_type, data), ()

        image = ImageOps.exif_transpose(original)
        image.thumbnail((MAX_RESIZED_SIDE, MAX_RESIZED_SIDE), Image.Resampling.LANCZOS)
        if image.has_transparency_data:
            rgba = image.convert("RGBA")
            rgb = Image.new("RGB", rgba.size, "white")
            rgb.paste(rgba, mask=rgba.getchannel("A"))
        else:
            rgb = image.convert("RGB")
        while True:
            with BytesIO() as output:
                rgb.save(output, format="JPEG", quality=91, optimize=True)
                if output.tell() <= byte_budget:
                    encoded = output.getvalue()
                    break
            if rgb.size == (1, 1):
                raise ValueError("Image cannot fit the vision request")
            rgb.thumbnail((max(1, rgb.width * 3 // 4), max(1, rgb.height * 3 // 4)), Image.Resampling.LANCZOS)

        limitations = ["모델 요청 한도에 맞춘 이미지 사본을 분석 대상으로 사용했습니다."]
        if animated:
            limitations.append("움직이는 이미지의 첫 프레임을 분석 대상으로 사용했습니다.")
        return ("image/jpeg", encoded), tuple(limitations)
