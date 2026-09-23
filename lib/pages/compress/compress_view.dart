import 'package:epub_image_compressor/models/compressor_job.dart';
import 'package:epub_image_compressor/pages/compress/timeline_view.dart';
import 'package:epub_image_compressor/utils/app_util.dart';
import 'package:epub_image_compressor/values/colors.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../routers/routes.dart';
import '../../values/values.dart';
import 'compress_logic.dart';

class CompressPage extends StatefulWidget {
  const CompressPage({super.key});

  @override
  State<CompressPage> createState() => _CompressPageState();
}

class _CompressPageState extends State<CompressPage> {
  final logic = Get.put(CompressLogic());
  final state = Get.find<CompressLogic>().state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: _buildOptionsBar(),
          ),
          state.buildVerticalDivider(),
          Expanded(
            flex: 3,
            child: _buildFileView(),
          ),
          state.buildVerticalDivider(),
          Expanded(flex: 2, child: TimelineView(logic: logic)),
        ],
      ),
    );
  }

  Widget _buildOptionsBar() {
    return Container(
      width: double.infinity,
      decoration: state.buildBoxDecoration(),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 8),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 50,
                alignment: Alignment.centerLeft,
                child: Text(
                  '压缩参数设置:',
                  style: state.buildTextStyle(16, fontWeight: FontWeight.bold),
                ),
              ),
              state.buildHorizontalDivider(),
              // 质量滑块：控制 JPEG 压缩的质量百分比。
              SizedBox(
                height: 50,
                child: Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: Text(
                        'JPEG压缩质量:',
                        style: state.buildTextStyle(12),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Obx(() => SizedBox(
                            width: 180,
                            child: Slider(
                              value: logic.quality.value.toDouble(),
                              activeColor: AppColors.primary,
                              inactiveColor: AppColors.surface,
                              min: 50,
                              max: 100,
                              divisions: 10,
                              label: '${logic.quality.value}',
                              onChanged: (v) => logic.quality.value = v.round(),
                            ),
                          )),
                    ),
                  ],
                ),
              ),
              Text('数值越小，压缩级别越大，压缩后的图片大小越小。默认60',
                  style: state.buildTextStyle(10, color: Colors.red)),
              state.buildHorizontalDivider(),
              // PNG 等级滑块：控制 PNG 图像的压缩级别（0~9）。
              SizedBox(
                height: 50,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                        flex: 1,
                        child:
                            Text('PNG压缩级别:', style: state.buildTextStyle(12))),
                    Expanded(
                      flex: 3,
                      child: Obx(() => SizedBox(
                            width: 180,
                            child: Slider(
                              value: logic.pngLevel.value.toDouble(),
                              activeColor: AppColors.primary,
                              inactiveColor: AppColors.surface,
                              min: 0,
                              max: 9,
                              divisions: 9,
                              label: '${logic.pngLevel.value}',
                              onChanged: (v) =>
                                  logic.pngLevel.value = v.round(),
                            ),
                          )),
                    ),
                  ],
                ),
              ),
              Text(
                  'PNG为无损压缩：数值越大压缩越狠、图片越小，画质不变（0=几乎不压缩、最大；9=极限压缩、最小）。默认6。仅对仍保留为PNG的图生效（不透明PNG已被转为JPEG时走上面的质量滑块）。',
                  style: state.buildTextStyle(10, color: Colors.red)),
              state.buildHorizontalDivider(),
              // 跳过小图开关：启用后将忽略小于指定大小的图片。
              SizedBox(
                height: 50,
                child: Row(
                  children: [
                    Expanded(
                        flex: 1,
                        child:
                            Text('是否跳过小图:', style: state.buildTextStyle(12))),
                    Expanded(
                      flex: 3,
                      child: Obx(
                        () => FilterChip(
                          label: Text(' (<${logic.minKb.value}KB)'),
                          selectedColor: AppColors.primary,
                          selected: logic.skipSmall.value,
                          onSelected: (v) => logic.skipSmall.value = v,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              state.buildHorizontalDivider(),
              // 阈值滑块：仅当跳过小图开启时可用，设定最小尺寸限制。
              Obx(
                () => SizedBox(
                  height: 50,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                        flex: 1,
                        child: Text(
                          '小图阈值设置：',
                          style: state.buildTextStyle(12),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Slider(
                          value: logic.minKb.value.toDouble(),
                          activeColor: AppColors.primary,
                          inactiveColor: AppColors.surface,
                          min: 10,
                          max: 200,
                          divisions: 20,
                          label: '${logic.minKb.value}KB',
                          onChanged: logic.skipSmall.value
                              ? (v) => logic.minKb.value = v.round()
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              state.buildHorizontalDivider(),
              // PNG转JPG开关：将不透明PNG重新编码为JPEG并同步更新引用。
              SizedBox(
                height: 50,
                child: Row(
                  children: [
                    Expanded(
                        flex: 1,
                        child:
                            Text('PNG转JPG:', style: state.buildTextStyle(12))),
                    Expanded(
                      flex: 3,
                      child: Obx(
                        () => FilterChip(
                          label: Text(
                            logic.convertPngToJpg.value ? '开启' : '关闭',
                          ),
                          selectedColor: AppColors.primary,
                          selected: logic.convertPngToJpg.value,
                          onSelected: (v) => logic.convertPngToJpg.value = v,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Text('开启后，不透明PNG将转为JPEG以进一步减小体积，并自动更新EPUB内引用。',
                  style: state.buildTextStyle(10, color: Colors.red)),
              state.buildHorizontalDivider(),
              // 透明PNG转JPG开关：把带透明的PNG先铺白底再转JPEG（有损）。
              Obx(
                () => SizedBox(
                  height: 50,
                  child: Row(
                    children: [
                      Expanded(
                          flex: 1,
                          child: Text('透明PNG转JPG:',
                              style: state.buildTextStyle(12))),
                      Expanded(
                        flex: 3,
                        child: FilterChip(
                          label: Text(
                            logic.convertTransparentPng.value ? '开启' : '关闭',
                          ),
                          selectedColor: AppColors.primary,
                          selected: logic.convertTransparentPng.value,
                          onSelected: logic.convertPngToJpg.value
                              ? (v) => logic.convertTransparentPng.value = v
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text('透明区域会被铺成白色背景（JPEG不支持透明），可能改变显示效果，默认关闭。',
                  style: state.buildTextStyle(10, color: Colors.red)),
              state.buildHorizontalDivider(),
              SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: state.buildButton(
                        "输出目录", logic.chooseOutputDir, Icons.folder_open),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      flex: 1,
                      child: state.buildButton(
                          "清空目录", logic.clearOutputDir, Icons.clear)),
                ],
              ),
              SizedBox(height: 5),
              Obx(
                () => Text(
                  logic.outputDir.value.isEmpty
                      ? '输出目录：未设置（默认按文件在原目录生成 epub_output_时间戳/）'
                      : '输出目录：${logic.outputDir.value}',
                  style: state.buildTextStyle(12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileView() {
    return Container(
      width: double.infinity,
      decoration: state.buildBoxDecoration(),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 8),
        child: Column(
          children: [
            SizedBox(
              height: 50,
              child: Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: state.buildButton(
                        "添加", logic.pickBatchFiles, Icons.playlist_add),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      flex: 1,
                      child: state.buildButton(
                          "清空", logic.clearBatch, Icons.clear_all)),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: Obx(() {
                      return state.buildButton(
                        logic.isRunning.value ? '取消' : '开始',
                        logic.handleFabPressed,
                        logic.isRunning.value ? Icons.stop : Icons.play_arrow,
                      );
                    }),
                  ),
                ],
              ),
            ),
            state.buildHorizontalDivider(),
            Obx(() {
              return SizedBox(
                height: 50,
                child: Row(
                  children: [
                    const Text('全局进度'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: state.newJobs.isNotEmpty
                            ? state.overallProgress.value
                            : 0.0,
                        backgroundColor: AppColors.divider,
                        valueColor: AlwaysStoppedAnimation(AppColors.primary),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(state.newJobs.isNotEmpty
                        ? '${(state.overallProgress.value * 100).toStringAsFixed(0)}%'
                        : '0/0'),
                  ],
                ),
              );
            }),
            const SizedBox(height: 12),
            Expanded(
              child: Obx(() {
                if (logic.state.newJobs.isEmpty) {
                  return const Center(child: Text('尚未添加 EPUB 文件。'));
                }
                return ListView.separated(
                  itemCount: logic.state.newJobs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final job = logic.state.newJobs[index];
                    return _buildFileItemView(job);
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileItemView(CompressorJob job) {
    return Container(
      decoration: state.buildBoxDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    "文件名：${job.fileName}",
                    style:
                        state.buildTextStyle(12, fontWeight: FontWeight.w500),
                  ),
                ),
                Obx(() {
                  final status = job.status.value;
                  return Chip(
                    label: Text(state.statusText(status)),
                    backgroundColor: AppColors.surface,
                    labelStyle: TextStyle(
                      color: AppColors.textPrimary,
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '源地址：${job.inputPath}',
              style: state.buildTextStyle(12),
            ),
            Obx(() {
              final status = job.status.value;
              final outputText = job.outputPath ??
                  job.outputDir ??
                  job.defaultOutputDir ??
                  '未确定';
              final canOpen = job.outputPath?.isNotEmpty == true &&
                  status == JobStatus.success;
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      '输出路径：$outputText',
                      style: state.buildTextStyle(12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '打开输出文件',
                    onPressed: canOpen ? () => logic.openOutputFile(job) : null,
                    icon: const Icon(Icons.open_in_new),
                    color: canOpen ? AppColors.primary : AppColors.divider,
                  ),
                ],
              );
            }),
            const SizedBox(height: 4),
            Obx(() {
              final originalText = job.originalBytes.value > 0
                  ? AppUtil.formatSize(job.originalBytes.value)
                  : '--';
              final compressedText = job.compressedBytes.value > 0
                  ? AppUtil.formatSize(job.compressedBytes.value)
                  : '未生成';
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      '原始大小：$originalText',
                      style: state.buildTextStyle(12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '压缩后：$compressedText',
                      style: state.buildTextStyle(12),
                    ),
                  ),
                ],
              );
            }),
            const SizedBox(height: 4),
            Obx(() => Text(
                  '耗时：${job.formattedElapsed}',
                  style: state.buildTextStyle(12),
                )),
            const SizedBox(height: 8),
            Obx(
              () => LinearProgressIndicator(
                value: job.progress.value,
                backgroundColor: AppColors.divider,
                valueColor: AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
            const SizedBox(height: 8),
            Obx(
              () => Row(
                children: [
                  Text(
                      '图片数量：${job.processedImages.value}/${job.totalImages.value}'),
                  const SizedBox(width: 12),
                  Text('节省：${AppUtil.formatSize(job.savedBytes.value)}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
