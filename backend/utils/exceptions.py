"""
自定义异常层次
所有异常继承自 FFmpegToolException，方便上层统一捕获
"""

class FFmpegToolException(Exception):
    """基础异常"""
    pass


class FFmpegNotFoundException(FFmpegToolException):
    """FFmpeg 未安装 / 不在 PATH 中"""
    def __init__(self, message="FFmpeg 未找到，请先安装 FFmpeg 并添加到系统 PATH"):
        self.message = message
        super().__init__(self.message)


class FFprobeNotFoundException(FFmpegToolException):
    """FFprobe 未安装 / 不在 PATH 中"""
    def __init__(self, message="FFprobe 未找到，请先安装 FFprobe 并添加到系统 PATH"):
        self.message = message
        super().__init__(self.message)


class VideoParseException(FFmpegToolException):
    """视频文件解析失败"""
    def __init__(self, message="视频文件解析失败"):
        self.message = message
        super().__init__(self.message)


class SubtitleParseException(FFmpegToolException):
    """字幕文件解析失败"""
    def __init__(self, message="字幕文件解析失败"):
        self.message = message
        super().__init__(self.message)


class InvalidParameterException(FFmpegToolException):
    """参数校验不通过"""
    def __init__(self, param: str, message: str = ""):
        self.param = param
        self.message = f"参数 '{param}' 无效: {message}"
        super().__init__(self.message)


class FileCorruptedException(FFmpegToolException):
    """文件损坏或无法读取"""
    def __init__(self, filepath: str, message: str = ""):
        self.filepath = filepath
        self.message = f"文件 '{filepath}' 损坏或无法读取: {message}"
        super().__init__(self.message)


class ProcessingException(FFmpegToolException):
    """ffmpeg 执行过程异常"""
    def __init__(self, message="视频处理过程中出现错误"):
        self.message = message
        super().__init__(self.message)


class CommandBuildException(FFmpegToolException):
    """命令构建失败"""
    def __init__(self, message="FFmpeg 命令构建失败"):
        self.message = message
        super().__init__(self.message)
