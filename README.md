# DartNeuralNetwork

A Swift-based iOS application for dartboard detection, dart scoring, and game tracking using computer vision and machine learning.

## Overview

DartNeuralNetwork scores darts from a single phone camera. A Core ML model finds the board and every dart tip, and the app plays X01 with the detected darts, which you can correct with one tap.

## Features

- **X01 games**: 301, 501, 701 or a custom start score, double out on or off, 1 to 4 players.
- **Live scoring from the camera**: each detected dart appears in its slot, coloured like the bed it hit. Tap a slot to correct it. Pulling the darts moves play to the next player.
- **Checkout routes** when a finish is possible, plus bust and checkout states.
- **Board status** in a small live camera tile; tap it to frame the board full screen.
- **Leg summary**: winner, 3-dart average, darts thrown, best visit, checkout and where the darts landed.

## Technical Implementation

Detection uses one Core ML model, `ML-Models/v6rf12_fp16.mlpackage`: RF-DETR Medium (576 x 576 input, fp16, Neural Engine), trained on Blender renders plus real photos. It finds 12 calibration points on the outer double wire and dart tips. Everything else is plain Swift:

- Decoding the model's 300 queries (sigmoid, top 300 over all class scores, duplicate merge), as in `tools/check_coreml.py` of the training repository (DartSynthetic)
- Image-to-board homography from the calibration points (DLT with an exhaustive RANSAC), no OpenCV
- Multi-frame tracking (`MultiFrameTracker`): the board locks once, the model then looks at a crop around the board, darts must persist over several frames, and pulled darts are seen as absent before play moves on

## Project Structure

- `Game/` - X01 rules, checkout routes, stats and board geometry as plain Swift types (unit tested in `DartNeuralNetworkTests`)
- `Detection/` - the `DartDetectionSource` protocol the game reads from. `RFDetr/` holds the detector: `RFDetrDetectionSource` (camera and threading), `DetectionEngine` (model + tracker on one serial queue), `MultiFrameTracker` (board lock, dart tracks, visits), `RFDetrModel` (preprocessing and decoding), `Homography`, and every tuning constant in `DetectorTuning`. `DemoDetectionSource` (DEBUG only) scripts detections for the simulator
- `Screens/` and `Design/` - SwiftUI screens and shared components. The full-screen camera view has a detector view toggle that draws what the detector sees

In the simulator, launch with `-demoScenario live` (or `bust`, `checkout`, `summary`, `searching`, ...) to open a scripted state. DEBUG builds can replay still photos through the real model: `-replayFolder <folder of jpgs> [-replayHold 6] [-replayFPS 8]`; add `-detectorDebugOverlay YES` to start with the detector view on.

## Tests

`xcodebuild test -scheme DartNeuralNetwork -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:DartNeuralNetworkTests` runs the unit tests: game rules, decoding against Python fixtures, homography, scoring geometry, the multi-frame tracker and the detection source. The accuracy tests also run the model on labelled photos in `DartNeuralNetworkTests/RealPhotos/`; those photos are private and not in this repository, so without them the photo tests skip.

## Getting Started

1. Clone the repository
2. Open the project in Xcode
3. Build and run on a compatible iOS device
4. Prop the phone up with the camera facing the board, pick a game and start

## Demo

The demo below shows the 2025 version of the app, before the redesign and the RF-DETR model.

![DartNeuralNetwork Demo](demo.gif)

## Acknowledgments

This project utilizes:
- Apple's Core ML framework
- RF-DETR (Apache 2.0) as the detector architecture
- Custom-trained machine learning models for dart and dartboard detection
- https://github.com/wmcnally/deep-darts for providing the initial picture dataset for dart detection

---

Created by Jan Buechele
