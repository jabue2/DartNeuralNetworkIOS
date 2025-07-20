# DartNeuralNetwork

A Swift-based iOS application for dartboard detection, dart scoring, and game tracking using computer vision and machine learning.

## Overview

DartNeuralNetwork is an iOS application that uses computer vision and machine learning techniques to detect dartboards, identify dart positions, and automatically score dart games. The app provides multiple functionalities including photo mode analysis, live detection, and game tracking.

## Features

### Photo Mode
- Take photos of dartboards and darts using the device camera
- Import existing photos from your library
- Automatic dartboard detection and cropping
- Full image processing pipeline for dart detection and scoring

### Live Detection
- Real-time dartboard and dart detection using the device camera
- Live scoring and position tracking
- Visual annotations for detected objects

### Game Mode
- Select from various dart game types
- Automatic scoring based on detected dart positions
- Track game progress and statistics

## Technical Implementation

The application employs several machine learning models:
- `dartboardDetector.mlmodel` - For detecting and localizing dartboards in images
- `456Medium60.mlmodel` - For dart detection
- Additional models for dart detection, tested for performance

Key components:
- Custom homography calculations for accurate dart position mapping
- Computer vision pipeline using CoreML and Vision frameworks
- SwiftUI for modern, responsive user interface
- OpenCV integration for advanced image processing

## Project Structure

The project is organized into several key components:

- **User Interface**
  - `ContentView.swift` - Main tab-based interface
  - `PhotoModeView.swift` - Interface for photo analysis mode
  - `LiveDetectionView.swift` - Interface for real-time detection
  - `GameSelectionView.swift` - Game selection and tracking interface

- **Core Functionality**
  - `DartboardProcessing.swift` - Core image processing and detection logic
  - `LiveDartDetectionController.swift` - Controller for live camera feed processing
  - `HomographyHelper.mm` - OpenCV-based homography calculations

- **Machine Learning Models**
  - `dartboardDetector.mlmodel` - Dartboard detection model
  - `456Medium60.mlmodel` - Dart detection model
  - Additional models for enhanced precision

## Getting Started

1. Clone the repository
2. Open the project in Xcode
3. Build and run on a compatible iOS device
4. Choose between Photo Mode, Live Detection, or Game Mode

## Demo

![DartNeuralNetwork Demo](demo.gif)

## Acknowledgments

This project utilizes:
- Apple's Vision and CoreML frameworks
- OpenCV for advanced computer vision algorithms
- Custom-trained machine learning models for dart and dartboard detection
- https://github.com/wmcnally/deep-darts for providing the initial picture dataset for dart detection

---

Created by Jan Buechele
